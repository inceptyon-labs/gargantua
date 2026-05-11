import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "RemnantScanner")

/// Builds uninstall plans for a single app — test seam for the Smart
/// Uninstaller UI.
public protocol UninstallPlanning: Sendable {
    func plan(for app: AppInfo, includeAppBundle: Bool) -> UninstallPlan
}

/// Builds uninstall plans by expanding remnant rules against one app.
public struct RemnantScanner: UninstallPlanning, Sendable {
    let rules: [RemnantRule]
    let scanRoots: [URL]
    let expander: PathExpander
    let receiptExpander: PackageReceiptExpander?
    let receiptBuilder: ReceiptRemnantBuilder?
    let observer: (any ScanProgressObserving)?

    public init(
        rules: [RemnantRule],
        scanRoots: [URL] = PathExpander.defaultScanRoots(),
        expander: PathExpander = PathExpander(),
        receiptExpander: PackageReceiptExpander? = nil,
        receiptBuilder: ReceiptRemnantBuilder? = nil,
        observer: (any ScanProgressObserving)? = nil
    ) {
        self.rules = rules
        self.scanRoots = scanRoots
        self.expander = expander
        self.receiptExpander = receiptExpander
        self.receiptBuilder = receiptBuilder
        self.observer = observer
    }

    /// Build a scanner against the bundled `uninstall_rules` directory.
    public static func loadDefaults(
        scanRoots: [URL]? = nil,
        observer: (any ScanProgressObserving)? = nil
    ) throws -> RemnantScanner {
        guard let url = Bundle.module.url(forResource: "uninstall_rules", withExtension: nil) else {
            throw RemnantScannerError.rulesDirectoryNotFound
        }

        let load = try RemnantRuleLoader().loadRules(from: url)
        for error in load.errors {
            logger.warning("Remnant rule parse error: \(error.localizedDescription, privacy: .public)")
        }

        return RemnantScanner(
            rules: load.rules,
            scanRoots: scanRoots ?? PathExpander.defaultScanRoots(),
            observer: observer
        )
    }

    /// Return a copy with a progress observer attached. Useful when the
    /// scanner is built once (e.g. `loadDefaults`) and later wired to a
    /// view-model-owned stream.
    public func withObserver(_ observer: any ScanProgressObserving) -> RemnantScanner {
        RemnantScanner(
            rules: rules,
            scanRoots: scanRoots,
            expander: expander,
            receiptExpander: receiptExpander,
            receiptBuilder: receiptBuilder,
            observer: observer
        )
    }

    /// Scan the filesystem for remnants owned by `app`.
    public func plan(for app: AppInfo, includeAppBundle: Bool = true) -> UninstallPlan {
        let applicable = rules
            .enumerated()
            .filter { _, rule in
                rule.appliesTo?.matches(bundleID: app.bundleID) ?? true
            }
            .sorted { lhs, rhs in
                let lhsPriority = Self.rulePriority(lhs.element)
                let rhsPriority = Self.rulePriority(rhs.element)
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        var remnants: [RemnantItem] = []
        var seenPaths: Set<String> = []

        for rule in applicable {
            let evaluation = evaluate(rule: rule, app: app)
            for item in evaluation.items
                where seenPaths.insert(item.path).inserted {
                remnants.append(item)
                observer?.didEmit(ScanProgressEvent(
                    path: item.path,
                    outcome: .match,
                    bytes: item.size
                ))
            }
            if rule.tags.contains("app_pack") {
                seenPaths.formUnion(evaluation.reservedPaths)
            }
        }

        appendReceiptEvidence(into: &remnants, seenPaths: &seenPaths, for: app)

        let bundle = includeAppBundle ? Self.makeAppBundleItem(for: app) : nil
        if let bundle {
            observer?.didEmit(ScanProgressEvent(
                path: bundle.path,
                outcome: .match,
                bytes: bundle.size
            ))
        }
        return UninstallPlan(app: app, appBundle: bundle, remnants: remnants)
    }
}
