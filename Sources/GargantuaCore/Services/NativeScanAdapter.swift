import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "NativeScanAdapter")

/// Native filesystem scanner driven by YAML rules.
///
/// Walks the paths declared in `ScanRule` files, measures sizes, applies
/// profile-aware safety overrides via `SafetyClassifier`, and emits `ScanResult`
/// values.
///
/// This is the Phase 1.5 replacement for the `mo clean` subprocess — the YAML
/// rules were hand-ported from Mole's domain knowledge and are now the
/// authoritative source of truth for what is scannable and how it is classified.
public struct NativeScanAdapter: ScanAdapter {
    private let rules: [ScanRule]
    private let profile: CleanupProfile
    private let classifier: SafetyClassifier
    private let scanRoots: [URL]
    private let expander: PathExpander
    private let processChecker: any RunningProcessChecking
    private let applicabilityChecker: any RuleApplicabilityChecking

    public init(
        rules: [ScanRule],
        profile: CleanupProfile = .light,
        classifier: SafetyClassifier = SafetyClassifier(),
        scanRoots: [URL] = PathExpander.defaultScanRoots(),
        expander: PathExpander = PathExpander(),
        processChecker: any RunningProcessChecking = DefaultRunningProcessChecker(),
        applicabilityChecker: any RuleApplicabilityChecking = DefaultRuleApplicabilityChecker()
    ) {
        self.rules = rules
        self.profile = profile
        self.classifier = classifier
        self.scanRoots = scanRoots
        self.expander = expander
        self.processChecker = processChecker
        self.applicabilityChecker = applicabilityChecker
    }

    /// Build a scanner against the YAML rules shipped with the app.
    ///
    /// Locates the `cleanup_rules` directory via `RuleDirectoryResolver`, loads
    /// every YAML file under it with `RuleLoader`, and returns a configured adapter.
    /// Rule-file parse errors are reported via the returned load result but do not
    /// abort — successfully-parsed rules are still used.
    ///
    /// - Parameters:
    ///   - profile: The cleanup profile whose `categories` gate which rules run.
    ///   - scanRoots: Optional override for the roots that glob patterns expand against.
    ///     `nil` uses `PathExpander.defaultScanRoots()`.
    public static func loadDefaults(
        profile: CleanupProfile,
        scanRoots: [URL]? = nil
    ) throws -> NativeScanAdapter {
        guard let dir = RuleDirectoryResolver.resolve() else {
            throw ScanAdapterError.rulesDirectoryNotFound
        }
        let load = try RuleLoader().loadRules(from: dir)
        for err in load.errors {
            logger.warning("Rule parse error: \(err.localizedDescription, privacy: .public)")
        }
        return NativeScanAdapter(
            rules: load.rules,
            profile: profile,
            scanRoots: scanRoots ?? PathExpander.defaultScanRoots()
        )
    }

    /// Run the scan against the configured rules and profile.
    ///
    /// - Parameter progress: Optional observer driven per-rule for UI feedback.
    /// - Returns: Scan results with final (classified) safety levels.
    public func scan(progress: ScanProgress? = nil) async throws -> [ScanResult] {
        try await scan(progress: progress, observer: nil)
    }

    /// Run the scan and emit per-path events to an EventHorizon-style observer.
    ///
    /// Each child the size walker visits emits a `.checked` event; each result
    /// that survives deduplication emits a `.match` event with byte count;
    /// per-rule warnings emit a `.failed` event.
    public func scan(
        progress: ScanProgress? = nil,
        observer: (any ScanProgressObserving)?
    ) async throws -> [ScanResult] {
        await progress?.start()

        let applicable = rules.filter { rule in
            profile.categories.isEmpty || profile.categories.contains(rule.category)
        }

        // Probe scan roots once for present ecosystems so rule evaluation can drop
        // `**/<leaf>` patterns whose ecosystem isn't represented anywhere — keeps the
        // UI from emitting "depth reached. 0 partial results." warnings for every
        // rule the user has no projects of (Angular, .NET, Zig, Terraform, etc.).
        let availableEcosystems = applicabilityChecker.availableEcosystems(in: scanRoots)
        let ecosystemList = availableEcosystems.map(\.rawValue).sorted().joined(separator: ",")
        logger.info(
            """
            NativeScanAdapter: \(applicable.count) rules match profile \
            \(profile.id, privacy: .public); \
            ecosystems present: \(ecosystemList, privacy: .public)
            """
        )

        var results: [ScanResult] = []
        var seenPaths: Set<String> = []
        var reclaimableBytes: Int64 = 0
        let total = max(applicable.count, 1)

        // Fire-and-forget sizing updates so the UI ticks per child path during a
        // rule whose `directorySize` walk would otherwise sit silent for seconds.
        // The same callback also feeds path-level events to the EventHorizon
        // console when an observer is attached.
        let observerRef = observer
        let onSizing: @Sendable (String) -> Void = { path in
            Task { @MainActor [weak progress] in
                progress?.noteSizing(path: path)
            }
            observerRef?.didEmit(ScanProgressEvent(path: path, outcome: .checked))
        }

        for (idx, rule) in applicable.enumerated() {
            await progress?.update(
                fractionCompleted: Double(idx) / Double(total),
                currentCategory: rule.category,
                itemsFound: results.count,
                reclaimableBytes: reclaimableBytes
            )

            let context = EvaluationContext(
                classifier: classifier,
                profile: profile,
                expander: expander,
                scanRoots: scanRoots,
                processChecker: processChecker,
                availableEcosystems: availableEcosystems
            )
            let evaluation = await Task.detached {
                Self.evaluate(rule: rule, context: context, onSizing: onSizing)
            }.value

            for warning in evaluation.warnings {
                await progress?.recordError(warning)
                observerRef?.didEmit(ScanProgressEvent(
                    path: rule.id,
                    outcome: .failed(reason: warning)
                ))
            }
            // Deduplicate by path across rules so overlapping rules don't double-count
            // bytes or trigger a second recycle attempt after the first succeeds.
            for result in evaluation.results where seenPaths.insert(result.path).inserted {
                results.append(result)
                reclaimableBytes += result.size
                observerRef?.didEmit(ScanProgressEvent(
                    path: result.path,
                    outcome: .match,
                    bytes: result.size
                ))
            }
        }

        await progress?.finish(itemsFound: results.count)
        logger.info("NativeScanAdapter: produced \(results.count) items")
        return results
    }
}
