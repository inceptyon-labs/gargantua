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
    /// Whether the executable's enclosing bundle resolved to an app still
    /// installed on disk. `nil` when no bundle evidence could be resolved
    /// (no identity, or identity has no bundle path) — not the same as
    /// `false`, which means the bundle was resolved and confirmed absent.
    public let parentAppInstalled: Bool?
    /// `true` when the label matches a well-known vendor but no app from
    /// that vendor is installed. Heuristic evidence only — weaker than
    /// `parentAppInstalled == false`, which is a direct bundle resolution.
    public let knownVendorAppMissing: Bool
    public let plist: LaunchdPlist?

    public init(
        label: String,
        source: BackgroundItemSource,
        plistPath: String?,
        executablePath: String?,
        identity: BinaryIdentity?,
        executableExists: Bool,
        parentAppInstalled: Bool? = nil,
        knownVendorAppMissing: Bool = false,
        plist: LaunchdPlist?
    ) {
        self.label = label
        self.source = source
        self.plistPath = plistPath
        self.executablePath = executablePath
        self.identity = identity
        self.executableExists = executableExists
        self.parentAppInstalled = parentAppInstalled
        self.knownVendorAppMissing = knownVendorAppMissing
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
///   - Deterministic suspicion signal (temp/Downloads exe, label/filename
///     mismatch, piped shell invocation) → review, chips always attached
///   - Owning app uninstalled (bundle resolved, confirmed absent) → safe
///   - Well-known vendor label, no app from that vendor installed (heuristic) → review
///   - Known non-critical vendor helper, parent app installed → safe
///   - Unsigned, unknown → review
///   - Default → review
///
/// Never auto-rates as safe based on signature alone — known-vendor safety
/// requires the parent bundle to be present on disk.
public struct BackgroundItemSafetyClassifier: Sendable {

    public init() {}

    public func classify(_ input: BackgroundItemClassifierInput) -> BackgroundItemClassification {
        var reasons = derivedReasons(for: input).union(suspiciousReasons(for: input))

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

        // 3.25 Suspicious signals force review — a suspicious item must never be
        //      auto-selected via a safe rule below, but the chips still show on
        //      every tier. No 4th SafetyLevel tier; suspicion is evidence.
        if reasons.contains(where: { $0.isSuspicious }) {
            return BackgroundItemClassification(safety: .review, reasons: reasons)
        }

        // 3.5 Owning app uninstalled (strong bundle evidence) — the executable may
        //     still exist (Application Support helpers outlive their app). Safe.
        if input.parentAppInstalled == false {
            // Deliberately NOT tagged `.orphaned` — that chip and the triage
            // copy say "orphaned executable", and this executable exists.
            // `.parentAppMissing` ("App Uninstalled") is the accurate story.
            reasons.insert(.parentAppMissing)
            return BackgroundItemClassification(safety: .safe, reasons: reasons)
        }

        // 3.75 Well-known vendor label with no installed app from that vendor —
        //      heuristic evidence only. Review, NEVER safe on its own; placed
        //      before the known-vendor-safe rule so conflicting evidence stays
        //      conservative.
        if input.knownVendorAppMissing {
            reasons.insert(.parentAppLikelyMissing)
            return BackgroundItemClassification(safety: .review, reasons: reasons)
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

    /// Deterministic suspicion signals. Advisory chips at every tier; rule 3.25
    /// forces `.review` so a suspicious item is never auto-selected as safe.
    private func suspiciousReasons(for input: BackgroundItemClassifierInput) -> Set<BackgroundItemReason> {
        var reasons: Set<BackgroundItemReason> = []
        if let exe = input.executablePath {
            let tmpRoots = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/"]
            if tmpRoots.contains(where: exe.hasPrefix) || exe.contains("/Downloads/") {
                reasons.insert(.suspiciousExecutablePath)
            }
        }
        if let plistPath = input.plistPath {
            let stem = URL(fileURLWithPath: plistPath).deletingPathExtension().lastPathComponent
            if stem.caseInsensitiveCompare(input.label) != .orderedSame {
                reasons.insert(.labelFilenameMismatch)
            }
        }
        if let args = input.plist?.programArguments, args.count >= 2 {
            let shells: Set<String> = ["sh", "bash", "zsh", "dash"]
            let interpreter = URL(fileURLWithPath: args[0]).lastPathComponent
            if shells.contains(interpreter), let cIndex = args.firstIndex(of: "-c") {
                let payload = args[(cIndex + 1)...].joined(separator: " ").lowercased()
                let patterns = ["curl", "wget", "| sh", "| bash", "|sh", "|bash", "eval "]
                if patterns.contains(where: payload.contains) {
                    reasons.insert(.shellInvocation)
                }
            }
        }
        return reasons
    }
}
