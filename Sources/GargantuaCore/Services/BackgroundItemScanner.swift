import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "BackgroundItemScanner")

/// Result of one Background Items scan pass.
public struct BackgroundItemScan: Sendable, Equatable {
    /// Resolved items, sorted by safety severity then label.
    public let items: [BackgroundItem]
    /// `true` when login-item enumeration could not return a list (typically
    /// because `sfltool dumpbtm` requires elevated privileges).
    public let loginItemsNeedPrivileges: Bool
    /// Items whose plists were on disk but could not be parsed. Surfaced so the
    /// UI can say "we saw N items we couldn't read" instead of silently
    /// dropping them.
    public let unparseableCount: Int
    /// When the scan completed.
    public let scannedAt: Date

    public init(
        items: [BackgroundItem],
        loginItemsNeedPrivileges: Bool,
        unparseableCount: Int,
        scannedAt: Date
    ) {
        self.items = items
        self.loginItemsNeedPrivileges = loginItemsNeedPrivileges
        self.unparseableCount = unparseableCount
        self.scannedAt = scannedAt
    }

    public static let empty = BackgroundItemScan(
        items: [],
        loginItemsNeedPrivileges: false,
        unparseableCount: 0,
        scannedAt: .distantPast
    )
}

/// Orchestrates `LaunchdItemIndex` + `LoginItemEnumerator` + `BinaryIdentityResolver`
/// + `BackgroundItemSafetyClassifier` + `BackgroundItemExplainer` into a single
/// `[BackgroundItem]` list.
public protocol BackgroundItemScanning: Sendable {
    func scan() -> BackgroundItemScan
}

public struct DefaultBackgroundItemScanner: BackgroundItemScanning {
    private let launchdIndex: any LaunchdItemIndexing
    private let loginItems: any LoginItemEnumerating
    private let resolver: any BinaryIdentityResolving
    private let classifier: BackgroundItemSafetyClassifier
    private let explainer: BackgroundItemExplainer
    private let runtimeProvider: any LaunchdRuntimeStateProviding
    private let appResolver: any OwningAppResolving
    private let fileExists: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date

    /// Org-domain prefixes (first two reverse-DNS components) of vendors whose
    /// launchd labels reliably indicate an owning app. Gate for the
    /// parentAppLikelyMissing heuristic — personal namespaces (com.jason.*)
    /// must never match.
    static let wellKnownVendorLabelPrefixes: Set<String> = [
        "com.adobe", "com.valvesoftware", "com.grammarly", "com.dropbox",
        "com.google", "com.microsoft", "org.mozilla", "com.spotify",
        "com.docker", "com.logi", "com.logitech", "com.brave", "com.razer",
        "com.corsair", "com.epicgames", "com.teamviewer", "com.citrix",
        "com.parallels", "com.vmware", "com.box", "com.evernote",
        "com.skype", "com.zoom", "us.zoom", "com.canon", "com.hp", "com.epson",
    ]

    public init(
        launchdIndex: any LaunchdItemIndexing = DefaultLaunchdItemIndex(),
        loginItems: any LoginItemEnumerating = DefaultLoginItemEnumerator(),
        resolver: any BinaryIdentityResolving = DefaultBinaryIdentityResolver(),
        classifier: BackgroundItemSafetyClassifier = BackgroundItemSafetyClassifier(),
        explainer: BackgroundItemExplainer = BackgroundItemExplainer(),
        runtimeProvider: any LaunchdRuntimeStateProviding = DefaultLaunchdRuntimeStateProvider(),
        appResolver: any OwningAppResolving = WorkspaceInstalledAppResolver(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.launchdIndex = launchdIndex
        self.loginItems = loginItems
        self.resolver = resolver
        self.classifier = classifier
        self.explainer = explainer
        self.runtimeProvider = runtimeProvider
        self.appResolver = appResolver
        self.fileExists = fileExists
        self.now = now
    }

    /// First two dot-components of a reverse-DNS label, lowercased; nil when
    /// the label has fewer than three components (no org+product shape).
    static func labelOrgPrefix(_ label: String) -> String? {
        let components = label.split(separator: ".")
        guard components.count >= 3 else { return nil }
        return "\(components[0]).\(components[1])".lowercased()
    }

    /// A bundle nested inside another bundle (embedded `.appex`, XPC service,
    /// helper `.app` in `Contents/`) is not separately Spotlight-indexed or
    /// LaunchServices-registered, so a resolver miss for its bundle id says
    /// nothing about whether the OUTER app is installed. Owning-app evidence
    /// is skipped for those rather than risking a false "app gone" on an
    /// active embedded helper.
    static func isNestedBundle(_ bundlePath: String?) -> Bool {
        guard let bundlePath else { return false }
        let bundleExtensions: Set<String> = ["app", "appex", "xpc", "framework", "bundle", "systemextension"]
        return (bundlePath as NSString).deletingLastPathComponent
            .split(separator: "/")
            .contains { bundleExtensions.contains(URL(fileURLWithPath: String($0)).pathExtension.lowercased()) }
    }

    /// Per-scan-pass memo for owning-app lookups, so a bundle id or vendor
    /// prefix shared by multiple background items is resolved at most once.
    /// A plain class (not an actor) is fine here — it's created and consumed
    /// entirely within one synchronous `scan()` call, never shared across
    /// concurrency domains.
    private final class ResolutionMemo {
        private var byBundleID: [String: Bool] = [:]
        private var byPrefix: [String: Bool] = [:]
        private var absenceConfirmable: Bool?

        func isInstalled(_ bundleID: String, using resolver: any OwningAppResolving) -> Bool {
            if let cached = byBundleID[bundleID] { return cached }
            let result = resolver.isInstalled(bundleID: bundleID)
            byBundleID[bundleID] = result
            return result
        }

        func isAnyInstalled(prefix: String, using resolver: any OwningAppResolving) -> Bool {
            if let cached = byPrefix[prefix] { return cached }
            let result = resolver.isAnyAppInstalled(bundleIDPrefix: prefix)
            byPrefix[prefix] = result
            return result
        }

        /// Probed at most once per scan pass — the health of the discovery
        /// layers doesn't change mid-scan.
        func canConfirmAbsence(using resolver: any OwningAppResolving) -> Bool {
            if let cached = absenceConfirmable { return cached }
            let result = resolver.canConfirmAppAbsence()
            absenceConfirmable = result
            return result
        }
    }

    public func scan() -> BackgroundItemScan {
        // The resolver caches by binary path + mtime, so a binary replaced at
        // the same path re-resolves on its own — no per-pass clear needed for a
        // replaced binary to lose its prior (possibly `safe`) classification.
        let launchdItems = launchdIndex.enumerate()
        // One batched snapshot for the whole pass — `makeItem` merges it
        // per row instead of shelling out per-item.
        let runtimeSnapshot = runtimeProvider.snapshot()
        let memo = ResolutionMemo()
        var items: [BackgroundItem] = []
        var unparseable = 0

        for launchd in launchdItems {
            if let plist = launchd.plist {
                items.append(makeItem(launchd: launchd, plist: plist, runtimeSnapshot: runtimeSnapshot, memo: memo))
            } else {
                unparseable += 1
            }
        }

        let loginEnum = loginItems.enumerate()
        for record in loginEnum.records {
            items.append(makeLoginItem(record))
        }

        items.sort(by: Self.severityOrdering)

        return BackgroundItemScan(
            items: items,
            loginItemsNeedPrivileges: loginEnum.needsPrivileges,
            unparseableCount: unparseable,
            scannedAt: now()
        )
    }

    // MARK: - Item construction

    private func makeItem(
        launchd: LaunchdItem,
        plist: LaunchdPlist,
        runtimeSnapshot: LaunchdRuntimeSnapshot,
        memo: ResolutionMemo
    ) -> BackgroundItem {
        let source = BackgroundItemSource(domain: launchd.domain)
        let exePath = plist.executablePath
        let identity = exePath.map(resolver.resolve)
        let exists = exePath.map(executableExists) ?? false

        // Owning-app evidence — only when the lookup can change the outcome:
        // Apple items are protected regardless; an exe-missing item is already
        // orphaned; login items never reach makeItem.
        var parentAppInstalled: Bool?
        var knownVendorAppMissing = false
        let isAppleShaped = plist.label.hasPrefix("com.apple.") || identity?.vendor == .apple
        if !isAppleShaped, exists {
            if let bundleID = identity?.bundleIdentifier, !Self.isNestedBundle(identity?.bundlePath) {
                if memo.isInstalled(bundleID, using: appResolver) {
                    parentAppInstalled = true
                } else if memo.canConfirmAbsence(using: appResolver) {
                    // A miss only counts as "the app is gone" when the
                    // resolver's discovery layers are healthy — with
                    // Spotlight indexing off, a present-but-unregistered
                    // app is invisible and absence must stay unknown (nil)
                    // rather than flip a helper to safe-to-remove.
                    parentAppInstalled = false
                }
            } else if let orgPrefix = Self.labelOrgPrefix(plist.label),
                      Self.wellKnownVendorLabelPrefixes.contains(orgPrefix),
                      memo.canConfirmAbsence(using: appResolver) {
                // Same health gate as the bundle path: with Spotlight off, a
                // prefix miss would paint a false "App Not Found" chip.
                knownVendorAppMissing = !memo.isAnyInstalled(prefix: orgPrefix + ".", using: appResolver)
            }
        }

        let classifierInput = BackgroundItemClassifierInput(
            label: plist.label,
            source: source,
            plistPath: launchd.plistPath,
            executablePath: exePath,
            identity: identity,
            executableExists: exists,
            parentAppInstalled: parentAppInstalled,
            knownVendorAppMissing: knownVendorAppMissing,
            plist: plist
        )
        let classification = classifier.classify(classifierInput)

        let explanation = explainer.explain(
            source: source,
            plist: plist,
            identity: identity,
            executableExists: exists,
            reasons: classification.reasons
        )

        let runtime = runtimeProvider.state(label: plist.label, source: source, snapshot: runtimeSnapshot)

        return BackgroundItem(
            id: makeID(source: source, label: plist.label, secondaryKey: launchd.plistPath),
            label: plist.label,
            source: source,
            plistPath: launchd.plistPath,
            executablePath: exePath,
            identity: identity,
            safety: classification.safety,
            reasons: classification.reasons,
            explanation: explanation,
            isOrphaned: isAbsolute(exePath) && !exists,
            runtime: runtime
        )
    }

    private func makeLoginItem(_ record: LoginItemRecord) -> BackgroundItem {
        let exePath = record.url?.path
        let identity = exePath.map(resolver.resolve)
        let exists = exePath.map(executableExists) ?? (record.url != nil)

        // Login-item IDs include the URL (or team identifier) as a secondary
        // key so multiple BTM records that share a bundle ID — e.g. an app's
        // main entry plus a helper at a separate URL — get distinct IDs and
        // don't collide in `ForEach` selection / expansion state.
        let secondary = record.url?.path ?? record.teamIdentifier

        let classifierInput = BackgroundItemClassifierInput(
            label: record.bundleIdentifier ?? record.name,
            source: .loginItem,
            plistPath: nil,
            executablePath: exePath,
            identity: identity,
            executableExists: exists,
            plist: nil
        )
        let classification = classifier.classify(classifierInput)

        let explanation = explainer.explain(
            source: .loginItem,
            plist: nil,
            identity: identity,
            executableExists: exists,
            reasons: classification.reasons
        )

        return BackgroundItem(
            id: makeID(source: .loginItem, label: record.bundleIdentifier ?? record.name, secondaryKey: secondary),
            label: record.name,
            source: .loginItem,
            plistPath: nil,
            executablePath: exePath,
            identity: identity,
            safety: classification.safety,
            reasons: classification.reasons,
            explanation: explanation,
            isOrphaned: isAbsolute(exePath) && !exists,
            // Login items have no launchd runtime — they're SMAppService /
            // Background Task Management records, not launchd jobs.
            runtime: nil
        )
    }

    /// `launchd` resolves bare program names through `_PATH_STDPATH`, so a
    /// `ProgramArguments[0]` like `"foo"` may be a perfectly valid job whose
    /// binary lives in `/usr/bin/foo`. Treat anything non-absolute as
    /// "exists, source unknown" rather than rushing it into the orphaned
    /// safe-cleanup bucket.
    private func executableExists(at path: String) -> Bool {
        guard isAbsolute(path) else { return true }
        return fileExists(path)
    }

    private func isAbsolute(_ path: String?) -> Bool {
        guard let path else { return false }
        return path.hasPrefix("/")
    }

    private func makeID(source: BackgroundItemSource, label: String, secondaryKey: String?) -> String {
        if let secondaryKey, !secondaryKey.isEmpty {
            return "\(source.rawSourceKey)|\(label)|\(secondaryKey)"
        }
        return "\(source.rawSourceKey)|\(label)"
    }

    // MARK: - Sort

    /// Sort order for the review pane: protected last (the user can't act on
    /// them), review before safe (those need attention), then by display label,
    /// then by id as a final tie-breaker so duplicate display names don't
    /// reorder scan-to-scan.
    static func severityOrdering(_ lhs: BackgroundItem, _ rhs: BackgroundItem) -> Bool {
        let lRank = severityRank(lhs.safety)
        let rRank = severityRank(rhs.safety)
        if lRank != rRank { return lRank < rRank }
        let nameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
        return lhs.id < rhs.id
    }

    private static func severityRank(_ safety: SafetyLevel) -> Int {
        switch safety {
        case .review: 0
        case .safe: 1
        case .protected_: 2
        }
    }
}

private extension BackgroundItemSource {
    var rawSourceKey: String {
        switch self {
        case .userLaunchAgent: "userAgent"
        case .systemLaunchAgent: "systemAgent"
        case .launchDaemon: "daemon"
        case .startupItem: "startup"
        case .loginItem: "loginItem"
        }
    }
}
