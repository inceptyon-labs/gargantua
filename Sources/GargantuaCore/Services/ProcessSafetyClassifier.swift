import Foundation

/// Output of `ProcessSafetyClassifier.classify(_:)`.
public struct ProcessClassification: Sendable, Equatable {
    public let safety: SafetyLevel
    public let reasons: Set<ProcessReason>
    public let explanation: String

    public init(safety: SafetyLevel, reasons: Set<ProcessReason>, explanation: String) {
        self.safety = safety
        self.reasons = reasons
        self.explanation = explanation
    }
}

/// Pre-computed inputs for the safety classifier. Built once per process by
/// `ProcessInventoryScanner` so the classifier itself remains pure: no I/O,
/// no globals, fully deterministic, easily unit-tested.
public struct ProcessClassifierInput: Sendable {
    public let command: String
    public let executablePath: String?
    public let uid: UInt32
    public let identity: BinaryIdentity?
    public let launchSource: ProcessLaunchSource
    public let launchConfidence: LaunchSourceConfidence
    /// `true` when the launchd item's executable is gone from disk but the
    /// process is alive (typical for a daemon left over from an uninstalled
    /// app). The scanner pre-resolves this from the file system.
    public let launchSourceOrphaned: Bool

    public init(
        command: String,
        executablePath: String?,
        uid: UInt32,
        identity: BinaryIdentity?,
        launchSource: ProcessLaunchSource,
        launchConfidence: LaunchSourceConfidence,
        launchSourceOrphaned: Bool
    ) {
        self.command = command
        self.executablePath = executablePath
        self.uid = uid
        self.identity = identity
        self.launchSource = launchSource
        self.launchConfidence = launchConfidence
        self.launchSourceOrphaned = launchSourceOrphaned
    }
}

/// Maps a `ProcessClassifierInput` to a `SafetyLevel` plus advisory reasons
/// and a one-line deterministic explanation.
///
/// Rules (first match wins):
///   1. Apple-signed under `/System/` or `/usr/`            → protected
///   2. Sensitive vendor (VPN/PM/MDM/etc.)                  → review
///   3. Foreground / GUI app source                         → review
///   4. Orphaned launchd source (process alive, plist gone) → safe
///   5. Known third-party vendor backed by a launchd item   → safe
///   6. Unsigned binary                                     → review
///   7. Default                                             → review
///
/// "Safe" never auto-fires from signature alone — it requires either an
/// orphaned source (cleanup win) or a known vendor with a launchd-managed
/// helper (will respawn cleanly when needed).
public struct ProcessSafetyClassifier: Sendable {

    public init() {}

    public func classify(_ input: ProcessClassifierInput) -> ProcessClassification {
        var reasons = derivedReasons(for: input)

        // 1. Apple system processes — always protected.
        if isAppleSystem(input) {
            reasons.insert(.system)
            return ProcessClassification(
                safety: .protected_,
                reasons: reasons,
                explanation: explanation(for: input, safety: .protected_, reasons: reasons)
            )
        }

        // 2. Sensitive vendor — review, regardless of signature validity.
        if let identity = input.identity, identity.isSensitiveVendor {
            reasons.insert(.sensitiveVendor)
            return ProcessClassification(
                safety: .review,
                reasons: reasons,
                explanation: explanation(for: input, safety: .review, reasons: reasons)
            )
        }

        // 3. Foreground / GUI app — review (the user is actively using it).
        if case .foregroundApp = input.launchSource {
            reasons.insert(.foregroundApp)
            return ProcessClassification(
                safety: .review,
                reasons: reasons,
                explanation: explanation(for: input, safety: .review, reasons: reasons)
            )
        }

        // 4. Orphaned launchd source — easy cleanup win.
        if input.launchSourceOrphaned {
            reasons.insert(.orphaned)
            return ProcessClassification(
                safety: .safe,
                reasons: reasons,
                explanation: explanation(for: input, safety: .safe, reasons: reasons)
            )
        }

        // 5. Known third-party vendor backed by a launchd item → safe.
        //    Only when the launchd link is `.exact` or `.path`; a label-only
        //    `.heuristic` match is too loose to auto-promote a process to
        //    "will respawn cleanly when needed" — it might just share a name
        //    with an unrelated plist.
        if case .launchd = input.launchSource,
           input.launchConfidence == .exact || input.launchConfidence == .path,
           let identity = input.identity,
           identity.vendor == .thirdPartyKnown,
           !identity.isSensitiveVendor {
            return ProcessClassification(
                safety: .safe,
                reasons: reasons,
                explanation: explanation(for: input, safety: .safe, reasons: reasons)
            )
        }

        // 6. Unsigned binary → review.
        if let identity = input.identity, identity.vendor == .unsigned {
            reasons.insert(.unsigned)
            return ProcessClassification(
                safety: .review,
                reasons: reasons,
                explanation: explanation(for: input, safety: .review, reasons: reasons)
            )
        }

        // 7. Default → review.
        return ProcessClassification(
            safety: .review,
            reasons: reasons,
            explanation: explanation(for: input, safety: .review, reasons: reasons)
        )
    }

    // MARK: - Reasons

    private func derivedReasons(for input: ProcessClassifierInput) -> Set<ProcessReason> {
        var reasons: Set<ProcessReason> = []
        if input.uid == 0 { reasons.insert(.rootProcess) }
        return reasons
    }

    private func isAppleSystem(_ input: ProcessClassifierInput) -> Bool {
        // The vendor anchor is the trust signal — `apple` only fires when
        // `BinaryIdentityResolver` saw `anchor apple` (Apple's first-party
        // platform identity), so a Developer-ID-signed binary in `/usr/local/`
        // can never sneak into protected.
        guard let identity = input.identity, identity.vendor == .apple else { return false }
        if let path = input.executablePath {
            if path.hasPrefix("/System/") || path.hasPrefix("/usr/") { return true }
        }
        if let bundlePath = identity.bundlePath {
            if bundlePath.hasPrefix("/System/") || bundlePath.hasPrefix("/usr/") { return true }
        }
        return false
    }

    // MARK: - Explanation

    private func explanation(
        for input: ProcessClassifierInput,
        safety: SafetyLevel,
        reasons: Set<ProcessReason>
    ) -> String {
        var parts: [String] = []

        if reasons.contains(.system) {
            parts.append("Apple system process")
        } else if let identity = input.identity {
            parts.append(signerPart(identity: identity))
        } else {
            parts.append("Process \(input.command)")
        }

        if let bundlePart = bundlePart(input: input) {
            parts.append(bundlePart)
        }

        parts.append(launchPart(input: input))

        if reasons.contains(.orphaned) {
            parts.append("source plist's binary is missing")
        } else if reasons.contains(.sensitiveVendor) {
            parts.append("vendor handles sensitive data")
        } else if safety == .safe, case .launchd = input.launchSource {
            parts.append("will relaunch when needed")
        }

        return parts.joined(separator: " · ")
    }

    private func signerPart(identity: BinaryIdentity) -> String {
        switch identity.vendor {
        case .apple:
            return "Signed by Apple"
        case .thirdPartyKnown:
            if let display = identity.vendorDisplayName, !display.isEmpty {
                return "Signed by \(display)"
            }
            if let team = identity.teamIdentifier, !team.isEmpty {
                return "Signed by team \(team)"
            }
            return "Signed (Developer ID)"
        case .thirdPartyUnknown:
            if let team = identity.teamIdentifier, !team.isEmpty {
                return "Signed by unknown team \(team)"
            }
            return "Signed by unknown developer"
        case .unsigned:
            return "Unsigned binary"
        }
    }

    private func bundlePart(input: ProcessClassifierInput) -> String? {
        if let identity = input.identity, let name = identity.bundleName, !name.isEmpty {
            return "ships with \(name)"
        }
        if let path = input.executablePath {
            let exe = (path as NSString).lastPathComponent
            if !exe.isEmpty { return "runs \(exe)" }
        }
        return nil
    }

    private func launchPart(input: ProcessClassifierInput) -> String {
        switch input.launchSource {
        case let .launchd(domain, _, _):
            switch domain {
            case .userAgent: return "via user LaunchAgent"
            case .systemAgent: return "via system LaunchAgent"
            case .systemDaemon: return "via LaunchDaemon"
            case .startupItem: return "via legacy StartupItem"
            }
        case .foregroundApp:
            return "foreground app"
        case .userSession:
            return "user session helper"
        case .childProcess:
            return "child of another process"
        case .unknown:
            return "no traceable source"
        }
    }
}
