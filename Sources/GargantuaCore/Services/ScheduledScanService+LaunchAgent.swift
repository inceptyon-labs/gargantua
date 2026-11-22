import Foundation
#if os(macOS)
    @preconcurrency import ServiceManagement
#endif

/// Static launch-agent identifiers and timing constants for scheduled scans.
public enum ScheduledScanLaunchAgentConfiguration {
    /// Bundle service label for the scheduler launch agent.
    ///
    /// Kept within the app's bundle-identifier domain (`com.inceptyon.gargantua.*`)
    /// to match the daemon/login-item labels and the plist filename SMAppService loads.
    public static let label = "com.inceptyon.gargantua.scheduler"
    /// Launch-agent plist file name embedded in the app bundle.
    public static let plistName = "\(label).plist"
    /// Relative app-bundle executable path for the scheduler.
    public static let bundleProgram = "Contents/MacOS/GargantuaScheduler"
    /// Polling interval used by the scheduler launch agent.
    public static let checkIntervalSeconds = 900
}

/// Factory for the property-list payload used by the scheduler launch agent.
public enum ScheduledScanLaunchAgentPlist {
    /// Builds the launch-agent dictionary before serialization.
    public static func makeDictionary(
        label: String = ScheduledScanLaunchAgentConfiguration.label,
        bundleProgram: String = ScheduledScanLaunchAgentConfiguration.bundleProgram,
        checkIntervalSeconds: Int = ScheduledScanLaunchAgentConfiguration.checkIntervalSeconds
    ) -> [String: Any] {
        [
            "Label": label,
            "BundleProgram": bundleProgram,
            "StartInterval": checkIntervalSeconds,
            "RunAtLoad": false,
            "StandardOutPath": "/tmp/gargantua-scheduler.log",
            "StandardErrorPath": "/tmp/gargantua-scheduler.log",
        ]
    }

    /// Serializes the scheduler launch-agent property list as XML data.
    public static func makeData(
        label: String = ScheduledScanLaunchAgentConfiguration.label,
        bundleProgram: String = ScheduledScanLaunchAgentConfiguration.bundleProgram,
        checkIntervalSeconds: Int = ScheduledScanLaunchAgentConfiguration.checkIntervalSeconds
    ) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: makeDictionary(
                label: label,
                bundleProgram: bundleProgram,
                checkIntervalSeconds: checkIntervalSeconds
            ),
            format: .xml,
            options: 0
        )
    }
}

/// ServiceManagement operations required by the scheduled scan controller.
public protocol ScheduledScanAgentInstalling: Sendable {
    /// Returns the current launch-agent status.
    func status() -> ScheduledScanAgentStatus
    /// Registers the launch agent and returns the resulting status.
    func register() throws -> ScheduledScanAgentStatus
    /// Unregisters the launch agent and returns the resulting status.
    func unregister() throws -> ScheduledScanAgentStatus
}

#if os(macOS)
    /// `SMAppService`-backed installer for the scheduled scan launch agent.
    public struct SMAppServiceScheduledScanAgentInstaller: ScheduledScanAgentInstalling, @unchecked Sendable {
        private let service: SMAppService

        /// Creates an installer for the named launch-agent plist.
        public init(plistName: String = ScheduledScanLaunchAgentConfiguration.plistName) {
            self.service = SMAppService.agent(plistName: plistName)
        }

        /// Returns the current normalized launch-agent status.
        public func status() -> ScheduledScanAgentStatus {
            ScheduledScanAgentStatus(service.status)
        }

        /// Registers the launch agent and returns the resulting status.
        public func register() throws -> ScheduledScanAgentStatus {
            try service.register()
            return status()
        }

        /// Unregisters the launch agent and returns the resulting status.
        public func unregister() throws -> ScheduledScanAgentStatus {
            try service.unregister()
            return status()
        }
    }
#endif

/// Coordinates scheduler launch-agent registration with user configuration.
public final class ScheduledScanController: @unchecked Sendable {
    private let installer: any ScheduledScanAgentInstalling

    /// Creates a controller using the platform default launch-agent installer.
    public init() {
        self.installer = defaultScheduledScanInstaller()
    }

    /// Creates a controller with an injected installer for testing or alternate backends.
    public init(installer: any ScheduledScanAgentInstalling) {
        self.installer = installer
    }

    /// Returns the current scheduler launch-agent status.
    public func status() -> ScheduledScanAgentStatus {
        installer.status()
    }

    @discardableResult
    /// Registers or unregisters the launch agent to match the supplied configuration.
    /// The agent stays registered while either background scans or background app-update checks are on.
    public func synchronize(
        configuration: ScheduledScanConfiguration,
        appUpdateChecks: Bool = false
    ) throws -> ScheduledScanAgentStatus {
        let current = installer.status()
        if configuration.isEnabled || appUpdateChecks {
            switch current {
            case .enabled, .requiresApproval:
                return current
            case .unavailable:
                // Platform doesn't support SMAppService launch agents (non-macOS).
                return current
            case .notFound, .notRegistered, .unknown:
                // `.notFound` is SMAppService's normal pre-registration state for an
                // agent — it reflects system-wide registration, not whether the plist
                // exists in the bundle (per Apple DTS). Register it like `.notRegistered`.
                // An unsigned dev build throws -67028 here; the caller surfaces that.
                return try installer.register()
            }
        } else {
            switch current {
            case .notRegistered, .notFound, .unavailable:
                return current
            case .enabled, .requiresApproval, .unknown:
                return try installer.unregister()
            }
        }
    }
}

private func defaultScheduledScanInstaller() -> any ScheduledScanAgentInstalling {
    return SMAppServiceScheduledScanAgentInstaller()
}

/// Plain-language reasons the background agent can't register.
public enum ScheduledScanAgentRegistrationFailure {
    public static let unsigned =
        "This copy of Gargantua isn't signed for background tasks, so macOS won't register its background agent. "
            + "Development builds hit this; the release build doesn't."
    public static let loginItemsApproval =
        "Allow Gargantua in System Settings > General > Login Items to run background checks."
    public static let missingAgent =
        "This copy of Gargantua is missing its background agent. Reinstall Gargantua to use background checks."
    private static let serviceManagementDomain = "SMAppServiceErrorDomain"
    public static let generic = "macOS couldn't register Gargantua's background agent."

    public static func message(for error: Error) -> String {
        #if os(macOS)
            let nsError = error as NSError
            guard nsError.domain == serviceManagementDomain else { return generic }
            switch nsError.code {
            case kSMErrorInvalidSignature: return unsigned
            case kSMErrorLaunchDeniedByUser: return loginItemsApproval
            // macOS 27 reports a missing plist as 108, "Unable to read plist".
            case kSMErrorJobPlistNotFound, 108: return missingAgent
            default: return generic
            }
        #else
            return generic
        #endif
    }
}
