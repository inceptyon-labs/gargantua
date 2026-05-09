import Foundation

/// Client-side façade for sending Background Item operations across the
/// privileged XPC boundary.
///
/// Mirrors the existing `XPCPrivilegedUninstallHelper` but for the
/// `performBackgroundItemAction` method on the same `@objc` protocol. Kept as
/// a separate type so callers don't reach into the uninstaller helper for
/// unrelated state, and so the system-domain Background Items flow can be
/// faked end-to-end in tests.
public protocol PrivilegedBackgroundItemHelping: Sendable {
    func perform(
        _ request: PrivilegedBackgroundItemRequest
    ) async -> PrivilegedBackgroundItemResponse
}

public final class XPCPrivilegedBackgroundItemHelper: PrivilegedBackgroundItemHelping, @unchecked Sendable {
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
    public func perform(
        _ request: PrivilegedBackgroundItemRequest
    ) async -> PrivilegedBackgroundItemResponse {
        do {
            let status = try ensureRegistered()
            guard status == .enabled else {
                return PrivilegedBackgroundItemResponse(
                    id: request.id,
                    succeeded: false,
                    error: approvalMessage(for: status)
                )
            }
            return await send(request)
        } catch {
            return PrivilegedBackgroundItemResponse(
                id: request.id,
                succeeded: false,
                error: error.localizedDescription
            )
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
    private func send(_ request: PrivilegedBackgroundItemRequest) async -> PrivilegedBackgroundItemResponse {
        do {
            let requestData = try PrivilegedUninstallXPCCodec.encoder.encode(request)
            let responseData = try await sendRequestData(requestData)
            if let response = try? PrivilegedUninstallXPCCodec.decoder.decode(
                PrivilegedBackgroundItemResponse.self,
                from: responseData
            ) {
                return response
            }
            // Helper falls back to the existing error envelope when it can't
            // decode the request — unwrap it into a Background Item response
            // so callers don't have to know about two error shapes.
            if let errorResponse = try? PrivilegedUninstallXPCCodec.decoder.decode(
                PrivilegedUninstallErrorResponse.self,
                from: responseData
            ) {
                return PrivilegedBackgroundItemResponse(
                    id: request.id,
                    succeeded: false,
                    error: errorResponse.error
                )
            }
            return PrivilegedBackgroundItemResponse(
                id: request.id,
                succeeded: false,
                error: "Unrecognized helper response."
            )
        } catch {
            return PrivilegedBackgroundItemResponse(
                id: request.id,
                succeeded: false,
                error: error.localizedDescription
            )
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

            proxy.performBackgroundItemAction(requestData: data) { responseData in
                connection.invalidate()
                continuation.resume(returning: responseData)
            }
        }
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
