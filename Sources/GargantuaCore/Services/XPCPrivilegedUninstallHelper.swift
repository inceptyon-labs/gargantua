import Foundation
@preconcurrency import ServiceManagement

public enum PrivilegedHelperConfiguration {
    public static let teamID = "3T877KDT79"
    public static let appBundleID = "com.inceptyon.gargantua"
    public static let helperBundleID = "com.inceptyon.gargantua.privileged-helper"
    public static let helperPlistName = "\(helperBundleID).plist"
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
        let requestByID = Dictionary(uniqueKeysWithValues: request.items.map { ($0.id, $0) })
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
