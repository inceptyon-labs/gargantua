import AppKit
import Foundation
import Security

/// Authorization token passed to privileged uninstall helpers.
///
/// Production callers should initialize this with an `AuthorizationRef`
/// obtained from Authorization Services. Tests may use the explicit testing
/// initializer so admin-path gating can be exercised without prompting.
public struct UninstallAuthorization: @unchecked Sendable {
    public let authorizationRef: AuthorizationRef?
    private let testingAuthorized: Bool

    public init(authorizationRef: AuthorizationRef) {
        self.authorizationRef = authorizationRef
        self.testingAuthorized = false
    }

    private init(testingAuthorized: Bool) {
        self.authorizationRef = nil
        self.testingAuthorized = testingAuthorized
    }

    var isAuthorized: Bool {
        authorizationRef != nil || testingAuthorized
    }

    static let authorizedForTesting = UninstallAuthorization(testingAuthorized: true)
}

/// Execution options for an uninstall plan.
public struct UninstallExecutionOptions: Sendable {
    public let dryRun: Bool
    public let includeProtectedItems: Bool
    public let confirmationMethod: ConfirmationTier
    public let cleanupMethod: CleanupMethod
    public let authorization: UninstallAuthorization?
    public let terminationTimeout: TimeInterval

    public init(
        dryRun: Bool = false,
        includeProtectedItems: Bool = false,
        confirmationMethod: ConfirmationTier,
        cleanupMethod: CleanupMethod = .trash,
        authorization: UninstallAuthorization? = nil,
        terminationTimeout: TimeInterval = 3
    ) {
        self.dryRun = dryRun
        self.includeProtectedItems = includeProtectedItems
        self.confirmationMethod = confirmationMethod
        self.cleanupMethod = cleanupMethod
        self.authorization = authorization
        self.terminationTimeout = terminationTimeout
    }
}

/// Aggregate result of executing an uninstall plan.
public struct UninstallExecutionResult: Sendable {
    public let cleanupResult: CleanupResult
    public let dryRun: Bool
    public let privilegedItems: [ScanResult]
    public let auditWritten: Bool

    public init(
        cleanupResult: CleanupResult,
        dryRun: Bool,
        privilegedItems: [ScanResult],
        auditWritten: Bool
    ) {
        self.cleanupResult = cleanupResult
        self.dryRun = dryRun
        self.privilegedItems = privilegedItems
        self.auditWritten = auditWritten
    }
}

public enum UninstallExecutionError: Error, Equatable, LocalizedError {
    case protectedItemsRequireFullModalOverride
    case authorizationRequired
    case unsupportedCleanupMethod(CleanupMethod)

    public var errorDescription: String? {
        switch self {
        case .protectedItemsRequireFullModalOverride:
            "Protected uninstall items require explicit full-modal confirmation."
        case .authorizationRequired:
            "Admin authorization is required to remove privileged uninstall items."
        case .unsupportedCleanupMethod(let method):
            "Uninstall execution supports Trash-first cleanup only, not \(method.rawValue)."
        }
    }
}

public protocol UninstallRemoving: AnyObject, Sendable {
    @MainActor
    func moveToTrash(_ item: ScanResult) async -> CleanupItemResult
}

public protocol PrivilegedUninstallHelping: AnyObject, Sendable {
    @MainActor
    func movePrivilegedItemsToTrash(
        _ items: [ScanResult],
        authorization: UninstallAuthorization
    ) async -> [CleanupItemResult]
}

public protocol RunningApplicationTerminating: AnyObject, Sendable {
    @MainActor
    func terminateRunningApplications(bundleIdentifier: String, timeout: TimeInterval) async -> Bool
}

public protocol UninstallAuditRecording: AnyObject, Sendable {
    @MainActor
    func write(_ entry: AuditEntry) throws
}

extension AuditWriter: UninstallAuditRecording {}

/// Executes an `UninstallPlan` — test seam for the Smart Uninstaller UI.
public protocol UninstallExecuting: Sendable {
    @MainActor
    func execute(
        _ plan: UninstallPlan,
        options: UninstallExecutionOptions
    ) async throws -> UninstallExecutionResult
}

/// Executes a Smart Uninstaller plan.
///
/// This layer is intentionally Trash-first. Non-privileged files are moved via
/// `NSWorkspace.recycle`; launch daemons and privileged helpers are delegated to
/// an authorized helper boundary because app-sandboxed code cannot remove them.
public final class UninstallExecutor: UninstallExecuting, Sendable {
    private let remover: any UninstallRemoving
    private let privilegedHelper: (any PrivilegedUninstallHelping)?
    private let processTerminator: any RunningApplicationTerminating
    private let auditRecorder: any UninstallAuditRecording

    public init(
        remover: any UninstallRemoving = WorkspaceUninstallRemover(),
        privilegedHelper: (any PrivilegedUninstallHelping)? = nil,
        processTerminator: any RunningApplicationTerminating = WorkspaceRunningApplicationTerminator(),
        auditRecorder: any UninstallAuditRecording = AuditWriter()
    ) {
        self.remover = remover
        self.privilegedHelper = privilegedHelper
        self.processTerminator = processTerminator
        self.auditRecorder = auditRecorder
    }

    @MainActor
    public func execute(
        _ plan: UninstallPlan,
        options: UninstallExecutionOptions
    ) async throws -> UninstallExecutionResult {
        guard options.cleanupMethod == .trash else {
            throw UninstallExecutionError.unsupportedCleanupMethod(options.cleanupMethod)
        }

        let items = plan.allItems
        let scanItems = items.map { $0.toScanResult() }
        if options.dryRun {
            return dryRunResult(items: scanItems)
        }

        try validateProtection(for: items, options: options)

        if plan.app.isRunning, scanItems.contains(where: { $0.path == plan.app.bundlePath }) {
            _ = await processTerminator.terminateRunningApplications(
                bundleIdentifier: plan.app.bundleID,
                timeout: options.terminationTimeout
            )
        }

        let privileged = scanItems.filter(Self.requiresPrivilegedHelper)
        let ordinary = scanItems.filter { !Self.requiresPrivilegedHelper($0) }
        let authorizedHelper = try preflightPrivilegedHelper(for: privileged, options: options)

        var itemResults: [CleanupItemResult] = []
        for item in ordinary {
            itemResults.append(await remover.moveToTrash(item))
        }

        if let authorizedHelper {
            itemResults.append(contentsOf: await authorizedHelper.helper.movePrivilegedItemsToTrash(
                privileged,
                authorization: authorizedHelper.authorization
            ))
        }

        let cleanupResult = CleanupResult(itemResults: itemResults, cleanupMethod: .trash)
        let auditWritten = try recordAudit(result: cleanupResult, confirmationMethod: options.confirmationMethod)

        return UninstallExecutionResult(
            cleanupResult: cleanupResult,
            dryRun: false,
            privilegedItems: privileged,
            auditWritten: auditWritten
        )
    }

    private func preflightPrivilegedHelper(
        for items: [ScanResult],
        options: UninstallExecutionOptions
    ) throws -> (helper: any PrivilegedUninstallHelping, authorization: UninstallAuthorization)? {
        guard !items.isEmpty else { return nil }
        guard let authorization = options.authorization, authorization.isAuthorized else {
            throw UninstallExecutionError.authorizationRequired
        }
        guard let privilegedHelper else {
            throw UninstallExecutionError.authorizationRequired
        }
        return (privilegedHelper, authorization)
    }

    private func validateProtection(
        for items: [RemnantItem],
        options: UninstallExecutionOptions
    ) throws {
        let hasProtected = items.contains { $0.safety == .protected_ }
        guard !hasProtected || (options.includeProtectedItems && options.confirmationMethod == .fullModal) else {
            throw UninstallExecutionError.protectedItemsRequireFullModalOverride
        }
    }

    private func dryRunResult(items: [ScanResult]) -> UninstallExecutionResult {
        let itemResults = items.map { item in
            CleanupItemResult(item: item, succeeded: true)
        }
        return UninstallExecutionResult(
            cleanupResult: CleanupResult(itemResults: itemResults, cleanupMethod: .trash),
            dryRun: true,
            privilegedItems: items.filter(Self.requiresPrivilegedHelper),
            auditWritten: false
        )
    }

    @MainActor
    private func recordAudit(result: CleanupResult, confirmationMethod: ConfirmationTier) throws -> Bool {
        let succeeded = result.succeededItems
        guard !succeeded.isEmpty else { return false }

        let entry = AuditEntry(
            tool: "uninstaller",
            command: "uninstall",
            files: succeeded.map { AuditFile(path: $0.item.path, size: $0.item.size) },
            safetyLevel: Self.highestSafety(in: succeeded.map(\.item)),
            confirmationMethod: confirmationMethod,
            cleanupMethod: .trash,
            bytesFreed: result.totalFreed
        )
        try auditRecorder.write(entry)
        return true
    }

    private static func highestSafety(in items: [ScanResult]) -> SafetyLevel {
        items.reduce(SafetyLevel.safe) { current, item in
            switch (current, item.safety) {
            case (.protected_, _), (_, .protected_): .protected_
            case (.review, _), (_, .review): .review
            default: .safe
            }
        }
    }

    private static func requiresPrivilegedHelper(_ item: ScanResult) -> Bool {
        item.category == RemnantCategory.launchDaemons.rawValue
            || item.category == RemnantCategory.helpers.rawValue
            || item.path.hasPrefix("/Library/LaunchDaemons/")
            || item.path.hasPrefix("/Library/PrivilegedHelperTools/")
    }
}

public final class WorkspaceUninstallRemover: UninstallRemoving {
    private let cleanupEngine: CleanupEngine

    public init(cleanupEngine: CleanupEngine = CleanupEngine()) {
        self.cleanupEngine = cleanupEngine
    }

    @MainActor
    public func moveToTrash(_ item: ScanResult) async -> CleanupItemResult {
        let result = await cleanupEngine.clean([item], method: .trash)
        return result.itemResults.first ?? CleanupItemResult(
            item: item,
            succeeded: false,
            error: "Cleanup engine returned no result."
        )
    }
}

public final class WorkspaceRunningApplicationTerminator: RunningApplicationTerminating {
    public init() {}

    @MainActor
    public func terminateRunningApplications(bundleIdentifier: String, timeout: TimeInterval) async -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard !apps.isEmpty else { return true }

        for app in apps where !app.isTerminated {
            app.terminate()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if apps.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        for app in apps where !app.isTerminated {
            app.forceTerminate()
        }

        return apps.allSatisfy(\.isTerminated)
    }
}
