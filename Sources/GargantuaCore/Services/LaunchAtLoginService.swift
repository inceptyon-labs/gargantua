import Foundation
#if os(macOS)
@preconcurrency import ServiceManagement
#endif

public enum LaunchAtLoginStatus: Sendable, Equatable, CustomStringConvertible {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unavailable
    case unknown(Int)

    #if os(macOS)
    public init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .unknown(status.rawValue)
        }
    }
    #endif

    public var description: String {
        switch self {
        case .notRegistered: "Not registered"
        case .enabled: "Enabled"
        case .requiresApproval: "Requires approval"
        case .notFound: "Login item not found in app bundle"
        case .unavailable: "Unavailable"
        case .unknown(let rawValue): "Unknown (\(rawValue))"
        }
    }
}

public protocol LaunchAtLoginInstalling: Sendable {
    func status() -> LaunchAtLoginStatus
    func register() throws -> LaunchAtLoginStatus
    func unregister() throws -> LaunchAtLoginStatus
}

#if os(macOS)
public struct SMAppServiceLaunchAtLoginInstaller: LaunchAtLoginInstalling, @unchecked Sendable {
    private let service: SMAppService

    public init(service: SMAppService = .mainApp) {
        self.service = service
    }

    public func status() -> LaunchAtLoginStatus {
        LaunchAtLoginStatus(service.status)
    }

    public func register() throws -> LaunchAtLoginStatus {
        try service.register()
        return status()
    }

    public func unregister() throws -> LaunchAtLoginStatus {
        try service.unregister()
        return status()
    }
}
#endif

public final class LaunchAtLoginController: @unchecked Sendable {
    private let installer: any LaunchAtLoginInstalling

    public init() {
        self.installer = defaultLaunchAtLoginInstaller()
    }

    public init(installer: any LaunchAtLoginInstalling) {
        self.installer = installer
    }

    public func status() -> LaunchAtLoginStatus {
        installer.status()
    }

    @discardableResult
    public func synchronize(isEnabled: Bool) throws -> LaunchAtLoginStatus {
        if isEnabled {
            let current = installer.status()
            switch current {
            case .enabled, .requiresApproval:
                return current
            case .notRegistered, .notFound, .unavailable, .unknown:
                return try installer.register()
            }
        } else {
            let current = installer.status()
            guard current != .notRegistered else { return current }
            return try installer.unregister()
        }
    }
}

private func defaultLaunchAtLoginInstaller() -> any LaunchAtLoginInstalling {
    #if os(macOS)
    return SMAppServiceLaunchAtLoginInstaller()
    #else
    return UnavailableLaunchAtLoginInstaller()
    #endif
}

private struct UnavailableLaunchAtLoginInstaller: LaunchAtLoginInstalling {
    func status() -> LaunchAtLoginStatus { .unavailable }
    func register() throws -> LaunchAtLoginStatus { .unavailable }
    func unregister() throws -> LaunchAtLoginStatus { .unavailable }
}
