import Foundation
import Testing
@testable import GargantuaCore

@Suite("UninstallExecutor")
struct UninstallExecutorTests {
    @Test("dry-run mode reports planned trash operations without moving files or writing audit")
    @MainActor
    func dryRunDoesNotMutate() async throws {
        let item = makeRemnant(
            id: "daemon",
            category: .launchDaemons,
            path: "/Library/LaunchDaemons/demo.plist",
            safety: .protected_
        )
        let executor = UninstallExecutor(
            remover: SpyUninstallRemover(),
            processTerminator: SpyProcessTerminator(),
            auditRecorder: SpyUninstallAuditRecorder()
        )

        let result = try await executor.execute(
            makePlan(remnants: [item]),
            options: UninstallExecutionOptions(dryRun: true, confirmationMethod: .singleButton)
        )

        #expect(result.dryRun)
        #expect(result.cleanupResult.allSucceeded)
        #expect(result.cleanupResult.totalFreed == item.size)
        #expect(result.auditWritten == false)
        #expect(result.privilegedItems.map(\.path) == [item.path])
    }

    @Test("trash execution moves non-privileged items and writes uninstaller audit entry")
    @MainActor
    func trashExecutionWritesAudit() async throws {
        let remover = SpyUninstallRemover()
        let audit = SpyUninstallAuditRecorder()
        let item = makeRemnant(id: "prefs", path: "/tmp/prefs.plist", safety: .review, size: 42)
        let executor = UninstallExecutor(
            remover: remover,
            processTerminator: SpyProcessTerminator(),
            auditRecorder: audit
        )

        let result = try await executor.execute(
            makePlan(remnants: [item]),
            options: UninstallExecutionOptions(confirmationMethod: .summaryDialog)
        )

        #expect(result.cleanupResult.allSucceeded)
        #expect(remover.removedPaths == [item.path])
        #expect(audit.entries.count == 1)
        #expect(audit.entries[0].tool == "uninstaller")
        #expect(audit.entries[0].command == "uninstall")
        #expect(audit.entries[0].confirmationMethod == .summaryDialog)
        #expect(audit.entries[0].cleanupMethod == .trash)
        #expect(audit.entries[0].bytesFreed == 42)
        #expect(audit.entries[0].files.map(\.path) == [item.path])
        #expect(result.auditWritten)
    }

    @Test("protected items require full-modal override before any operation runs")
    @MainActor
    func protectedItemsRequireOverride() async throws {
        let remover = SpyUninstallRemover()
        let item = makeRemnant(id: "daemon", category: .launchDaemons, path: "/Library/LaunchDaemons/demo.plist", safety: .protected_)
        let executor = UninstallExecutor(
            remover: remover,
            processTerminator: SpyProcessTerminator(),
            auditRecorder: SpyUninstallAuditRecorder()
        )

        await #expect(throws: UninstallExecutionError.protectedItemsRequireFullModalOverride) {
            _ = try await executor.execute(
                makePlan(remnants: [item]),
                options: UninstallExecutionOptions(confirmationMethod: .summaryDialog)
            )
        }
        #expect(remover.removedPaths.isEmpty)
    }

    @Test("admin-path items are gated behind an authorized privileged helper")
    @MainActor
    func adminPathGating() async throws {
        let helper = SpyPrivilegedUninstallHelper()
        let item = makeRemnant(id: "helper", category: .helpers, path: "/Library/PrivilegedHelperTools/com.demo.helper", safety: .protected_)
        let executor = UninstallExecutor(
            remover: SpyUninstallRemover(),
            privilegedHelper: helper,
            processTerminator: SpyProcessTerminator(),
            auditRecorder: SpyUninstallAuditRecorder()
        )

        await #expect(throws: UninstallExecutionError.authorizationRequired) {
            _ = try await executor.execute(
                makePlan(remnants: [item]),
                options: UninstallExecutionOptions(includeProtectedItems: true, confirmationMethod: .fullModal)
            )
        }

        let result = try await executor.execute(
            makePlan(remnants: [item]),
            options: UninstallExecutionOptions(
                includeProtectedItems: true,
                confirmationMethod: .fullModal,
                authorization: .authorizedForTesting
            )
        )

        #expect(helper.removedPaths == [item.path])
        #expect(helper.requests.map { $0.items.map(\.path) } == [[item.path]])
        #expect(result.privilegedItems.map(\.path) == [item.path])
        #expect(result.cleanupResult.allSucceeded)
    }

    @Test("non-writable Applications app bundles are routed through privileged helper")
    @MainActor
    func nonWritableApplicationsBundleUsesPrivilegedHelper() async throws {
        let helper = SpyPrivilegedUninstallHelper()
        let app = makeApp()
        let bundle = makeRemnant(
            id: "bundle",
            category: .other,
            path: app.bundlePath,
            safety: .review,
            tags: ["app_bundle"]
        )
        let executor = UninstallExecutor(
            remover: SpyUninstallRemover(),
            privilegedHelper: helper,
            processTerminator: SpyProcessTerminator(),
            auditRecorder: SpyUninstallAuditRecorder(),
            pathExists: { path in path == app.bundlePath },
            isWritablePath: { path in path != app.bundlePath }
        )

        let result = try await executor.execute(
            UninstallPlan(app: app, appBundle: bundle),
            options: UninstallExecutionOptions(
                confirmationMethod: .summaryDialog,
                authorization: .authorizedForTesting
            )
        )

        #expect(helper.removedPaths == [app.bundlePath])
        #expect(helper.requests.count == 1)
        #expect(helper.requests[0].items.map(\.path) == [app.bundlePath])
        #expect(helper.requests[0].items.map(\.operation) == [.moveToTrash])
        #expect(result.privilegedItems.map(\.path) == [app.bundlePath])
    }

    @Test("writable Applications app bundles stay on ordinary trash path")
    @MainActor
    func writableApplicationsBundleUsesWorkspaceTrash() async throws {
        let remover = SpyUninstallRemover()
        let helper = SpyPrivilegedUninstallHelper()
        let app = makeApp()
        let bundle = makeRemnant(
            id: "bundle",
            category: .other,
            path: app.bundlePath,
            safety: .review,
            tags: ["app_bundle"]
        )
        let executor = UninstallExecutor(
            remover: remover,
            privilegedHelper: helper,
            processTerminator: SpyProcessTerminator(),
            auditRecorder: SpyUninstallAuditRecorder(),
            pathExists: { path in path == app.bundlePath },
            isWritablePath: { _ in true }
        )

        let result = try await executor.execute(
            UninstallPlan(app: app, appBundle: bundle),
            options: UninstallExecutionOptions(confirmationMethod: .summaryDialog)
        )

        #expect(remover.removedPaths == [app.bundlePath])
        #expect(helper.removedPaths.isEmpty)
        #expect(result.privilegedItems.isEmpty)
    }

    @Test("missing authorization for non-writable app bundle prevents ordinary remnants from being trashed")
    @MainActor
    func nonWritableBundlePreflightPreventsPartialRemoval() async throws {
        let remover = SpyUninstallRemover()
        let app = makeApp()
        let bundle = makeRemnant(id: "bundle", category: .other, path: app.bundlePath, safety: .review)
        let ordinary = makeRemnant(id: "cache", path: "/tmp/cache", safety: .safe)
        let executor = UninstallExecutor(
            remover: remover,
            privilegedHelper: SpyPrivilegedUninstallHelper(),
            processTerminator: SpyProcessTerminator(),
            auditRecorder: SpyUninstallAuditRecorder(),
            pathExists: { path in path == app.bundlePath },
            isWritablePath: { path in path != app.bundlePath }
        )

        await #expect(throws: UninstallExecutionError.authorizationRequired) {
            _ = try await executor.execute(
                UninstallPlan(app: app, appBundle: bundle, remnants: [ordinary]),
                options: UninstallExecutionOptions(confirmationMethod: .summaryDialog)
            )
        }

        #expect(remover.removedPaths.isEmpty)
    }

    @Test("missing admin authorization is checked before ordinary items are trashed")
    @MainActor
    func adminPreflightPreventsPartialRemoval() async throws {
        let remover = SpyUninstallRemover()
        let ordinary = makeRemnant(id: "cache", path: "/tmp/cache", safety: .safe)
        let privileged = makeRemnant(
            id: "daemon",
            category: .launchDaemons,
            path: "/Library/LaunchDaemons/demo.plist",
            safety: .protected_
        )
        let executor = UninstallExecutor(
            remover: remover,
            privilegedHelper: SpyPrivilegedUninstallHelper(),
            processTerminator: SpyProcessTerminator(),
            auditRecorder: SpyUninstallAuditRecorder()
        )

        await #expect(throws: UninstallExecutionError.authorizationRequired) {
            _ = try await executor.execute(
                makePlan(remnants: [ordinary, privileged]),
                options: UninstallExecutionOptions(includeProtectedItems: true, confirmationMethod: .fullModal)
            )
        }

        #expect(remover.removedPaths.isEmpty)
    }

    @Test("running app bundles are terminated before bundle trash")
    @MainActor
    func runningAppBundleTerminatesBeforeTrash() async throws {
        let remover = SpyUninstallRemover()
        let terminator = SpyProcessTerminator()
        let app = makeApp(isRunning: true)
        let bundle = makeRemnant(
            id: "bundle",
            category: .other,
            path: app.bundlePath,
            safety: .review,
            tags: ["app_bundle"]
        )
        let executor = UninstallExecutor(
            remover: remover,
            processTerminator: terminator,
            auditRecorder: SpyUninstallAuditRecorder()
        )

        _ = try await executor.execute(
            UninstallPlan(app: app, appBundle: bundle),
            options: UninstallExecutionOptions(confirmationMethod: .summaryDialog)
        )

        #expect(terminator.terminatedBundleIDs == [app.bundleID])
        #expect(remover.removedPaths == [app.bundlePath])
    }

    private func makePlan(remnants: [RemnantItem]) -> UninstallPlan {
        UninstallPlan(app: makeApp(), remnants: remnants)
    }

    private func makeApp(isRunning: Bool = false) -> AppInfo {
        AppInfo(
            bundleID: "com.example.Demo",
            name: "Demo",
            bundlePath: "/Applications/Demo.app",
            isRunning: isRunning,
            sizeOnDisk: 100
        )
    }

    private func makeRemnant(
        id: String,
        category: RemnantCategory = .caches,
        path: String,
        safety: SafetyLevel,
        size: Int64 = 100,
        tags: [String] = []
    ) -> RemnantItem {
        RemnantItem(
            id: id,
            appBundleID: "com.example.Demo",
            category: category,
            path: path,
            size: size,
            safety: safety,
            confidence: 95,
            explanation: "Test remnant",
            source: SourceAttribution(name: "Demo", bundleID: "com.example.Demo"),
            ruleID: "test",
            tags: tags
        )
    }
}

@MainActor
private final class SpyUninstallRemover: UninstallRemoving {
    private(set) var removedPaths: [String] = []

    func moveToTrash(_ item: ScanResult) async -> CleanupItemResult {
        removedPaths.append(item.path)
        return CleanupItemResult(
            item: item,
            succeeded: true,
            trashURL: URL(fileURLWithPath: "/Users/test/.Trash/\(item.id)")
        )
    }
}

@MainActor
private final class SpyPrivilegedUninstallHelper: PrivilegedUninstallHelping {
    private(set) var removedPaths: [String] = []
    private(set) var requests: [PrivilegedUninstallRequest] = []

    func movePrivilegedItemsToTrash(
        _ request: PrivilegedUninstallRequest,
        authorization: UninstallAuthorization
    ) async -> [CleanupItemResult] {
        requests.append(request)
        removedPaths.append(contentsOf: request.items.map(\.path))
        return request.items.map { item in
            let scanResult = ScanResult(
                id: item.id,
                name: URL(fileURLWithPath: item.path).lastPathComponent,
                path: item.path,
                size: item.size,
                safety: .review,
                confidence: 100,
                explanation: "Privileged test result",
                source: SourceAttribution(name: "Demo", bundleID: "com.example.Demo"),
                category: item.category
            )
            return CleanupItemResult(
                item: scanResult,
                succeeded: true,
                trashURL: URL(fileURLWithPath: "/Users/test/.Trash/\(item.id)")
            )
        }
    }
}

@MainActor
private final class SpyProcessTerminator: RunningApplicationTerminating {
    private(set) var terminatedBundleIDs: [String] = []

    func terminateRunningApplications(bundleIdentifier: String, timeout: TimeInterval) async -> Bool {
        terminatedBundleIDs.append(bundleIdentifier)
        return true
    }
}

@MainActor
private final class SpyUninstallAuditRecorder: UninstallAuditRecording {
    private(set) var entries: [AuditEntry] = []

    func write(_ entry: AuditEntry) throws {
        entries.append(entry)
    }
}
