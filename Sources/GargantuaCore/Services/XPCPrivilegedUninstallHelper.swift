import Foundation
@preconcurrency import ServiceManagement

public enum PrivilegedHelperConfiguration {
    public static let teamID = "3T877KDT79"
    public static let appBundleID = "com.inceptyon.gargantua"
    public static let helperBundleID = "com.inceptyon.gargantua.privileged-helper"
    public static let helperPlistName = "\(helperBundleID).plist"

    /// Compiled into both the app and the helper. The app pings the running
    /// daemon for its version before a privileged op; a mismatch (or a helper
    /// too old to answer) means an app update left a stale daemon loaded, so the
    /// app force-reloads it. **Bump on any change to the helper's behavior.**
    ///
    /// - 1: original uninstaller-only helper (no version ping).
    /// - 2: tier-1 system allowlist, /private firmlink canonicalization,
    ///   user-Trash relocation, and this version handshake.
    /// - 3: bounded `deleteFromTrash` operation (empty root-owned items from the
    ///   invoking user's own Trash).
    public static let helperVersion = 3

    /// Code signing requirement the privileged helper enforces on incoming XPC
    /// connections. `anchor apple generic` pins the chain to a Developer ID
    /// signature; the leaf OU check binds the caller to our Team ID; the
    /// identifier check binds it to the app bundle. The XPC framework evaluates
    /// this per connection before the listener delegate runs, so it is race-free
    /// (no PID-reuse window like a manual SecCodeCopyGuestWithAttributes check).
    public static let codeSigningRequirement =
        "identifier \"\(appBundleID)\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(teamID)\""

    /// True when this bundle actually ships the launch daemon plist. `SMAppService`
    /// reports `.notFound` both for a build with no helper (a raw `swift build`) and
    /// for a signed release macOS declines to register, so the status alone can't
    /// tell the user which one they're in — this can.
    public static func isHelperBundled(
        bundleURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let plist = bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(helperPlistName)
        return fileManager.fileExists(atPath: plist.path)
    }
}

public enum PrivilegedHelperStatus: Sendable, Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown(Int)

    public init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered:
            self = .notRegistered
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .notFound
        @unknown default:
            self = .unknown(status.rawValue)
        }
    }
}

extension PrivilegedHelperStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notRegistered:
            "notRegistered"
        case .enabled:
            "enabled"
        case .requiresApproval:
            "requiresApproval"
        case .notFound:
            "notFound"
        case .unknown(let rawValue):
            "unknown(\(rawValue))"
        }
    }
}

public protocol PrivilegedUninstallHelperInstalling: Sendable {
    func status() -> PrivilegedHelperStatus
    func register() throws -> PrivilegedHelperStatus
    func unregister() throws -> PrivilegedHelperStatus
}

public struct SMAppServicePrivilegedHelperInstaller: PrivilegedUninstallHelperInstalling, @unchecked Sendable {
    private let service: SMAppService

    public init(plistName: String = PrivilegedHelperConfiguration.helperPlistName) {
        self.service = SMAppService.daemon(plistName: plistName)
    }

    public func status() -> PrivilegedHelperStatus {
        PrivilegedHelperStatus(service.status)
    }

    public func register() throws -> PrivilegedHelperStatus {
        try service.register()
        return status()
    }

    public func unregister() throws -> PrivilegedHelperStatus {
        try service.unregister()
        return status()
    }
}

public final class XPCPrivilegedUninstallHelper: PrivilegedUninstallHelping, @unchecked Sendable {
    private let installer: any PrivilegedUninstallHelperInstalling
    private let machServiceName: String

    public init(
        installer: any PrivilegedUninstallHelperInstalling = SMAppServicePrivilegedHelperInstaller(),
        machServiceName: String = PrivilegedHelperConfiguration.helperBundleID
    ) {
        self.installer = installer
        self.machServiceName = machServiceName
    }

    @MainActor
    public func movePrivilegedItemsToTrash(
        _ request: PrivilegedUninstallRequest,
        authorization: UninstallAuthorization
    ) async -> [CleanupItemResult] {
        guard authorization.isAuthorized else {
            return failureResults(for: request, message: "Privileged helper authorization is missing.")
        }

        do {
            let status = try ensureRegistered()
            guard status == .enabled else {
                return failureResults(for: request, message: approvalMessage(for: status))
            }
            try await reloadStaleHelperIfNeeded()
            return await send(request)
        } catch {
            return failureResults(for: request, message: error.localizedDescription)
        }
    }

    private func ensureRegistered() throws -> PrivilegedHelperStatus {
        let current = installer.status()
        switch current {
        case .enabled, .requiresApproval:
            return current
        case .notRegistered, .notFound:
            return try installer.register()
        case .unknown:
            return current
        }
    }

    /// True when the running daemon's reported version doesn't match this build.
    /// A `nil` running version (an older helper with no `helperVersion` method,
    /// or an unreachable one) counts as stale: when we can't confirm the helper
    /// is current, reload rather than trust it.
    static func shouldReloadHelper(running: Int?) -> Bool {
        running != PrivilegedHelperConfiguration.helperVersion
    }

    /// Ping the running daemon; if an app update left a stale one loaded, force a
    /// reload so launchd spawns the current binary on the next connection. The
    /// daemon is on-demand (no KeepAlive), so unregister/register drops the stale
    /// process and the subsequent `send` brings up the new one.
    @MainActor
    private func reloadStaleHelperIfNeeded() async throws {
        let running = await currentHelperVersion()
        guard Self.shouldReloadHelper(running: running) else { return }
        _ = try? installer.unregister()
        _ = try installer.register()
        // Give launchd a moment to tear the stale job down before we reconnect.
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @MainActor
    private func currentHelperVersion() async -> Int? {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedUninstallXPCProtocol.self)
            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                connection.invalidate()
                continuation.resume(returning: nil)
            } as? PrivilegedUninstallXPCProtocol

            guard let proxy else {
                connection.invalidate()
                continuation.resume(returning: nil)
                return
            }

            proxy.helperVersion { version in
                connection.invalidate()
                continuation.resume(returning: version)
            }
        }
    }

    @MainActor
    private func send(_ request: PrivilegedUninstallRequest) async -> [CleanupItemResult] {
        do {
            let requestData = try PrivilegedUninstallXPCCodec.encoder.encode(request)
            let responseData = try await sendRequestData(requestData)
            if let response = try? PrivilegedUninstallXPCCodec.decoder.decode(
                PrivilegedUninstallResponse.self,
                from: responseData
            ) {
                return cleanupResults(from: response, request: request)
            }
            let errorResponse = try PrivilegedUninstallXPCCodec.decoder.decode(
                PrivilegedUninstallErrorResponse.self,
                from: responseData
            )
            return failureResults(for: request, message: errorResponse.error)
        } catch {
            return failureResults(for: request, message: error.localizedDescription)
        }
    }

    @MainActor
    private func sendRequestData(_ data: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(
                machServiceName: machServiceName,
                options: .privileged
            )
            connection.remoteObjectInterface = NSXPCInterface(
                with: PrivilegedUninstallXPCProtocol.self
            )
            connection.invalidationHandler = {}
            connection.interruptionHandler = {}
            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                connection.invalidate()
                continuation.resume(throwing: error)
            } as? PrivilegedUninstallXPCProtocol

            guard let proxy else {
                connection.invalidate()
                continuation.resume(throwing: XPCPrivilegedUninstallHelperError.proxyUnavailable)
                return
            }

            proxy.moveItemsToTrash(requestData: data) { responseData in
                connection.invalidate()
                continuation.resume(returning: responseData)
            }
        }
    }

    private func cleanupResults(
        from response: PrivilegedUninstallResponse,
        request: PrivilegedUninstallRequest
    ) -> [CleanupItemResult] {
        // A duplicate item id in the request must not trap the reply handler.
        // Keep the first occurrence; the response is keyed by the same ids.
        let requestByID = Dictionary(request.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return response.items.map { result in
            let item = requestByID[result.id] ?? PrivilegedUninstallItem(
                id: result.id,
                path: result.path,
                category: RemnantCategory.other.rawValue,
                size: 0
            )
            return CleanupItemResult(
                item: scanResult(from: item),
                succeeded: result.succeeded,
                trashURL: result.trashPath.map { URL(fileURLWithPath: $0) },
                error: result.error
            )
        }
    }

    private func failureResults(
        for request: PrivilegedUninstallRequest,
        message: String
    ) -> [CleanupItemResult] {
        request.items.map { item in
            CleanupItemResult(
                item: scanResult(from: item),
                succeeded: false,
                error: message
            )
        }
    }

    private func scanResult(from item: PrivilegedUninstallItem) -> ScanResult {
        ScanResult(
            id: item.id,
            name: URL(fileURLWithPath: item.path).lastPathComponent,
            path: item.path,
            size: item.size,
            safety: .protected_,
            confidence: 100,
            explanation: "Privileged uninstall item",
            source: SourceAttribution(name: "Gargantua", bundleID: PrivilegedHelperConfiguration.appBundleID),
            category: item.category
        )
    }

    private func approvalMessage(for status: PrivilegedHelperStatus) -> String {
        switch status {
        case .requiresApproval:
            "Privileged helper requires approval in System Settings > General > Login Items & Extensions."
        case .notRegistered:
            "Privileged helper is not registered."
        case .notFound:
            "Privileged helper launch daemon plist was not found in the app bundle."
        case .enabled:
            "Privileged helper is enabled."
        case .unknown(let rawValue):
            "Privileged helper status is unknown (\(rawValue))."
        }
    }
}

public enum XPCPrivilegedUninstallHelperError: Error, LocalizedError {
    case proxyUnavailable

    public var errorDescription: String? {
        switch self {
        case .proxyUnavailable:
            "Unable to create privileged helper XPC proxy."
        }
    }
}
