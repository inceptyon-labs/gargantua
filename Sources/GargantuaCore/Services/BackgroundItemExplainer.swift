import Foundation

/// Generates the one-line deterministic explanation for a `BackgroundItem`.
///
/// Composition:
///   `<source kind> · signed by <vendor> · ships with <bundle> · <trigger>`
///
/// Pieces are dropped when their input is unavailable so the line never reads
/// "signed by Unknown" or "triggered by nothing." AI fallback runs on top of
/// this string for unsigned/unknown binaries.
public struct BackgroundItemExplainer: Sendable {

    public init() {}

    public func explain(
        source: BackgroundItemSource,
        plist: LaunchdPlist?,
        identity: BinaryIdentity?,
        executableExists: Bool
    ) -> String {
        var parts: [String] = []

        parts.append(sourcePart(source))

        if let signer = signerPart(identity: identity) {
            parts.append(signer)
        }

        if let bundle = bundlePart(identity: identity, executablePath: plist?.executablePath) {
            parts.append(bundle)
        }

        if !executableExists, plist?.executablePath != nil || identity?.bundlePath != nil {
            parts.append("target binary missing")
        }

        if let trigger = triggerPart(plist: plist) {
            parts.append(trigger)
        }

        return parts.joined(separator: " · ")
    }

    // MARK: - Pieces

    private func sourcePart(_ source: BackgroundItemSource) -> String {
        switch source {
        case .userLaunchAgent: "User LaunchAgent"
        case .systemLaunchAgent: "System LaunchAgent"
        case .launchDaemon: "LaunchDaemon (root)"
        case .startupItem: "StartupItem (legacy)"
        case .loginItem: "Login Item"
        }
    }

    private func signerPart(identity: BinaryIdentity?) -> String? {
        guard let identity else { return nil }
        switch identity.vendor {
        case .apple:
            return "signed by Apple"
        case .thirdPartyKnown:
            if let display = identity.vendorDisplayName, !display.isEmpty {
                return "signed by \(display)"
            }
            if let team = identity.teamIdentifier, !team.isEmpty {
                return "signed by team \(team)"
            }
            return "signed (Developer ID)"
        case .thirdPartyUnknown:
            if let team = identity.teamIdentifier, !team.isEmpty {
                return "signed by unknown team \(team)"
            }
            return "signed by unknown developer"
        case .unsigned:
            return "unsigned"
        }
    }

    private func bundlePart(identity: BinaryIdentity?, executablePath: String?) -> String? {
        if let identity, let bundleName = identity.bundleName, !bundleName.isEmpty {
            return "ships with \(bundleName)"
        }
        if let executablePath {
            let exe = (executablePath as NSString).lastPathComponent
            if !exe.isEmpty {
                return "runs \(exe)"
            }
        }
        return nil
    }

    private func triggerPart(plist: LaunchdPlist?) -> String? {
        guard let plist else { return nil }

        var triggers: [String] = []

        if plist.runAtLoad {
            triggers.append("runs at load")
        }
        if plist.keepAlive {
            triggers.append("kept alive")
        }
        if let interval = plist.startInterval {
            triggers.append("every \(formatInterval(interval))")
        }
        if !plist.startCalendarInterval.isEmpty {
            triggers.append("on schedule")
        }
        if !plist.watchPaths.isEmpty {
            triggers.append("on path change")
        }
        if !plist.queueDirectories.isEmpty {
            triggers.append("on queue")
        }
        if !plist.machServices.isEmpty {
            triggers.append("on Mach service request")
        } else if !plist.sockets.isEmpty {
            triggers.append("on socket activity")
        }

        if triggers.isEmpty { return nil }
        return triggers.joined(separator: ", ")
    }

    private func formatInterval(_ seconds: Int) -> String {
        if seconds % 86400 == 0 {
            let d = seconds / 86400
            return "\(d) day\(d == 1 ? "" : "s")"
        }
        if seconds % 3600 == 0 {
            let h = seconds / 3600
            return "\(h) hour\(h == 1 ? "" : "s")"
        }
        if seconds % 60 == 0 {
            let m = seconds / 60
            return "\(m) min"
        }
        return "\(seconds)s"
    }
}
