import Foundation

/// Output of `BackgroundItemSafetyClassifier.classify(_:)`.
public struct BackgroundItemClassification: Sendable, Equatable {
    public let safety: SafetyLevel
    public let reasons: Set<BackgroundItemReason>

    public init(safety: SafetyLevel, reasons: Set<BackgroundItemReason>) {
        self.safety = safety
        self.reasons = reasons
    }
}

/// Inputs the classifier needs about a single background item.
///
/// Built once per item by `BackgroundItemScanner` so the classifier itself
/// stays a pure function — no I/O, no globals, fully testable from constants.
public struct BackgroundItemClassifierInput: Sendable {
    public let label: String
    public let source: BackgroundItemSource
    public let plistPath: String?
    public let executablePath: String?
    public let identity: BinaryIdentity?
    public let executableExists: Bool
    public let plist: LaunchdPlist?

    public init(
        label: String,
        source: BackgroundItemSource,
        plistPath: String?,
        executablePath: String?,
        identity: BinaryIdentity?,
        executableExists: Bool,
        plist: LaunchdPlist?
    ) {
        self.label = label
        self.source = source
        self.plistPath = plistPath
        self.executablePath = executablePath
        self.identity = identity
        self.executableExists = executableExists
        self.plist = plist
    }
}

/// Deterministic safety mapping for background items.
///
/// Implements the rules from the parent feature:
///   - Apple-signed + path under `/System/` or `/usr/` → protected
///   - `com.apple.*` label → protected
///   - Sensitive vendor (VPN/PM/MDM/etc.) → review
///   - Orphaned vendor binary → safe (with `orphaned` reason)
///   - Known non-critical vendor helper, parent app installed → safe
///   - Unsigned, unknown → review
///   - Default → review
///
/// Never auto-rates as safe based on signature alone — known-vendor safety
/// requires the parent bundle to be present on disk.
public struct BackgroundItemSafetyClassifier: Sendable {

    public init() {}

    public func classify(_ input: BackgroundItemClassifierInput) -> BackgroundItemClassification {
        var reasons = derivedReasons(for: input)

        // 1. Apple system rules — protected.
        if isAppleSystem(input) {
            reasons.insert(.system)
            return BackgroundItemClassification(safety: .protected_, reasons: reasons)
        }

        // 2. Sensitive vendor — review, regardless of signature validity.
        if let identity = input.identity, identity.isSensitiveVendor {
            reasons.insert(.sensitiveVendor)
            return BackgroundItemClassification(safety: .review, reasons: reasons)
        }

        // 3. Orphaned (executable referenced by plist no longer on disk).
        //    Safe-by-default — these are the easy cleanup wins.
        if !input.executableExists, input.executablePath != nil {
            reasons.insert(.orphaned)
            if input.identity?.bundlePath != nil {
                reasons.insert(.orphanedVendor)
            }
            return BackgroundItemClassification(safety: .safe, reasons: reasons)
        }

        // 4. Known non-sensitive vendor with parent bundle present → safe.
        if let identity = input.identity,
           identity.vendor == .thirdPartyKnown,
           !identity.isSensitiveVendor,
           identity.bundlePath != nil {
            return BackgroundItemClassification(safety: .safe, reasons: reasons)
        }

        // 5. Unsigned → review.
        if let identity = input.identity, identity.vendor == .unsigned {
            reasons.insert(.unsigned)
            return BackgroundItemClassification(safety: .review, reasons: reasons)
        }

        // 6. Login items default to review (we deep-link rather than control them).
        //    Default for everything else: review.
        return BackgroundItemClassification(safety: .review, reasons: reasons)
    }

    // MARK: - Helpers

    private func isAppleSystem(_ input: BackgroundItemClassifierInput) -> Bool {
        if input.label.hasPrefix("com.apple.") { return true }

        guard let identity = input.identity, identity.vendor == .apple else { return false }
        if let path = input.executablePath {
            if path.hasPrefix("/System/") || path.hasPrefix("/usr/") { return true }
        }
        if let bundlePath = identity.bundlePath {
            if bundlePath.hasPrefix("/System/") || bundlePath.hasPrefix("/usr/") { return true }
        }
        return false
    }

    private func derivedReasons(for input: BackgroundItemClassifierInput) -> Set<BackgroundItemReason> {
        var reasons: Set<BackgroundItemReason> = []
        guard let plist = input.plist else { return reasons }

        if plist.disabled { reasons.insert(.disabledFlag) }
        if !plist.machServices.isEmpty || !plist.sockets.isEmpty {
            reasons.insert(.listensForRequests)
        }
        if plist.runAtLoad || plist.keepAlive {
            reasons.insert(.persistentlyRunning)
        }
        if plist.startInterval != nil || !plist.startCalendarInterval.isEmpty
            || !plist.watchPaths.isEmpty || !plist.queueDirectories.isEmpty {
            reasons.insert(.scheduled)
        }
        return reasons
    }
}
