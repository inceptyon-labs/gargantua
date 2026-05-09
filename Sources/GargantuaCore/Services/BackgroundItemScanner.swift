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
    private let fileExists: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date

    public init(
        launchdIndex: any LaunchdItemIndexing = DefaultLaunchdItemIndex(),
        loginItems: any LoginItemEnumerating = DefaultLoginItemEnumerator(),
        resolver: any BinaryIdentityResolving = DefaultBinaryIdentityResolver(),
        classifier: BackgroundItemSafetyClassifier = BackgroundItemSafetyClassifier(),
        explainer: BackgroundItemExplainer = BackgroundItemExplainer(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.launchdIndex = launchdIndex
        self.loginItems = loginItems
        self.resolver = resolver
        self.classifier = classifier
        self.explainer = explainer
        self.fileExists = fileExists
        self.now = now
    }

    public func scan() -> BackgroundItemScan {
        let launchdItems = launchdIndex.enumerate()
        var items: [BackgroundItem] = []
        var unparseable = 0

        for launchd in launchdItems {
            if let plist = launchd.plist {
                items.append(makeItem(launchd: launchd, plist: plist))
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

    private func makeItem(launchd: LaunchdItem, plist: LaunchdPlist) -> BackgroundItem {
        let source = BackgroundItemSource(domain: launchd.domain)
        let exePath = plist.executablePath
        let identity = exePath.map(resolver.resolve)
        let exists = exePath.map(fileExists) ?? false

        let classifierInput = BackgroundItemClassifierInput(
            label: plist.label,
            source: source,
            plistPath: launchd.plistPath,
            executablePath: exePath,
            identity: identity,
            executableExists: exists,
            plist: plist
        )
        let classification = classifier.classify(classifierInput)

        let explanation = explainer.explain(
            source: source,
            plist: plist,
            identity: identity,
            executableExists: exists
        )

        return BackgroundItem(
            id: makeID(source: source, label: plist.label, plistPath: launchd.plistPath),
            label: plist.label,
            source: source,
            plistPath: launchd.plistPath,
            executablePath: exePath,
            identity: identity,
            safety: classification.safety,
            reasons: classification.reasons,
            explanation: explanation,
            isOrphaned: !exists && exePath != nil
        )
    }

    private func makeLoginItem(_ record: LoginItemRecord) -> BackgroundItem {
        let exePath = record.url?.path
        let identity = exePath.map(resolver.resolve)
        let exists = exePath.map(fileExists) ?? (record.url != nil)

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
            executableExists: exists
        )

        return BackgroundItem(
            id: makeID(source: .loginItem, label: record.bundleIdentifier ?? record.name, plistPath: nil),
            label: record.name,
            source: .loginItem,
            plistPath: nil,
            executablePath: exePath,
            identity: identity,
            safety: classification.safety,
            reasons: classification.reasons,
            explanation: explanation,
            isOrphaned: !exists && exePath != nil
        )
    }

    private func makeID(source: BackgroundItemSource, label: String, plistPath: String?) -> String {
        if let plistPath {
            return "\(source.rawSourceKey)|\(label)|\(plistPath)"
        }
        return "\(source.rawSourceKey)|\(label)"
    }

    // MARK: - Sort

    /// Sort order for the review pane: protected last (the user can't act on
    /// them), review before safe (those need attention), then by display label.
    static func severityOrdering(_ lhs: BackgroundItem, _ rhs: BackgroundItem) -> Bool {
        let lRank = severityRank(lhs.safety)
        let rRank = severityRank(rhs.safety)
        if lRank != rRank { return lRank < rRank }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
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
