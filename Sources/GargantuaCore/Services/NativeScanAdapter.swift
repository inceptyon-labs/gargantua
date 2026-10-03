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
    // Internal (not private) so the `classify(path:)` extension in
    // NativeScanAdapter+Classify.swift can reverse-match against the same
    // rules/profile/classifier the forward scan uses.
    let rules: [ScanRule]
    let profile: CleanupProfile
    let classifier: SafetyClassifier
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
        let loader = RuleLoader()
        let load = try loader.loadRules(from: dir)
        for err in load.errors {
            logger.warning("Rule parse error: \(err.localizedDescription, privacy: .public)")
        }

        var rules = load.rules
        let userLoad = (try? loader.loadRules(from: UserRuleDirectory.directory(for: .cleanup)))
            ?? RuleLoadResult(rules: [], errors: [], filesLoaded: 0)
        for err in userLoad.errors {
            logger.warning("User rule parse error: \(err.localizedDescription, privacy: .public)")
        }
        if !userLoad.rules.isEmpty {
            let merged = UserRuleSanitizer.merge(
                bundled: rules,
                user: userLoad.rules,
                sanitizing: UserRuleSanitizer.sanitize
            )
            rules = merged.rules
            for id in merged.droppedIDs {
                logger.warning("User cleanup rule '\(id, privacy: .public)' ignored — id collides with a bundled rule.")
            }
        }

        return NativeScanAdapter(
            rules: rules,
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
        var indexByPath: [String: Int] = [:]

        // Fire-and-forget sizing updates so the UI ticks per child path during a
        // rule whose `directorySize` walk would otherwise sit silent for seconds.
        // The same callback also feeds path-level events to the EventHorizon
        // console when an observer is attached.
        let observerRef = observer
        // `noteSizing` only ever shows the latest path, so a per-path main-actor
        // Task is pure churn during a deep `directorySize` walk. Coalesce to at
        // most one hop per runloop tick, always publishing the newest path.
        let sizingLatch = SizingLatch()
        let onSizing: @Sendable (String) -> Void = { path in
            if sizingLatch.stage(path) {
                Task { @MainActor [weak progress] in
                    if let latest = sizingLatch.takeLatest() {
                        progress?.noteSizing(path: latest)
                    }
                }
            }
            observerRef?.didEmit(ScanProgressEvent(path: path, outcome: .checked))
        }

        // Evaluate rules concurrently, then fold results in rule order. Fanning
        // the independent glob walks across cores turns a serial re-enumeration
        // of the same roots (once per `**` rule) into a parallel sweep, while
        // rule-ordered folding keeps cross-rule "first rule wins" dedup — and
        // every id, size, and safety level — byte-for-byte identical to a serial
        // scan; only wall-clock changes.
        let evaluations = await evaluateConcurrently(
            applicable,
            availableEcosystems: availableEcosystems,
            onSizing: onSizing,
            progress: progress,
            referenceDate: Date()
        )

        for (idx, evaluation) in evaluations.enumerated() {
            guard let evaluation else { continue }
            let rule = applicable[idx]
            for warning in evaluation.warnings {
                await progress?.recordError(warning)
                observerRef?.didEmit(ScanProgressEvent(
                    path: rule.id,
                    outcome: .failed(reason: warning)
                ))
            }
            // Deduplicate by path across rules so overlapping rules don't double-count
            // bytes or trigger a second recycle attempt after the first succeeds.
            // The surviving entry takes the stricter rule's safety and any app
            // lock, so a broad safe rule can't unlock a path a specific rule guards.
            for result in evaluation.results {
                if let existing = indexByPath[result.path] {
                    results[existing] = ScanResultOverlapReconciler.stricter(results[existing], result)
                    continue
                }
                indexByPath[result.path] = results.count
                results.append(result)
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

    /// Evaluate every applicable rule concurrently, returning each rule's
    /// `RuleEvaluation` slotted at its original index so the caller can fold and
    /// deduplicate in deterministic rule order.
    ///
    /// Concurrency is bounded to the core count; a single `DirectorySizeCache` is
    /// shared across all rules so a directory resolved by more than one rule is
    /// sized exactly once.
    private func evaluateConcurrently(
        _ applicable: [ScanRule],
        availableEcosystems: Set<RuleEcosystem>,
        onSizing: @escaping @Sendable (String) -> Void,
        progress: ScanProgress?,
        referenceDate: Date
    ) async -> [RuleEvaluation?] {
        let sizeCache = DirectorySizeCache()
        let total = max(applicable.count, 1)
        let maxConcurrent = max(1, min(applicable.count, ProcessInfo.processInfo.activeProcessorCount))
        var evaluations = [RuleEvaluation?](repeating: nil, count: applicable.count)

        await withTaskGroup(of: (Int, RuleEvaluation).self) { group in
            var next = 0
            func enqueue() {
                guard next < applicable.count else { return }
                let idx = next
                let rule = applicable[idx]
                let context = EvaluationContext(
                    classifier: classifier,
                    profile: profile,
                    expander: expander,
                    scanRoots: scanRoots,
                    processChecker: processChecker,
                    availableEcosystems: availableEcosystems,
                    sizeCache: sizeCache,
                    referenceDate: referenceDate
                )
                group.addTask {
                    (idx, Self.evaluate(rule: rule, context: context, onSizing: onSizing))
                }
                next += 1
            }
            for _ in 0 ..< maxConcurrent { enqueue() }

            // A display-only running dedup keeps the "items found" / reclaimable
            // ticker rising as rules complete. It folds in completion order rather
            // than rule order, but dedup-by-path is order-independent for the count
            // and each path's size is rule-independent, so it converges to exactly
            // the authoritative totals the post-group fold posts at `finish` — the
            // live number never overshoots or disagrees with the final one.
            var seenForDisplay: Set<String> = []
            var displayItems = 0
            var displayBytes: Int64 = 0
            var completed = 0
            while let (idx, evaluation) = await group.next() {
                evaluations[idx] = evaluation
                completed += 1
                for result in evaluation.results where seenForDisplay.insert(result.path).inserted {
                    displayItems += 1
                    displayBytes += result.size
                }
                await progress?.update(
                    fractionCompleted: Double(completed) / Double(total),
                    currentCategory: applicable[idx].category,
                    itemsFound: displayItems,
                    reclaimableBytes: displayBytes
                )
                enqueue()
            }
        }
        return evaluations
    }
}

/// Coalesces a burst of sizing-path pings into at most one main-actor hop per
/// runloop tick. Only the newest path matters (it overwrites `currentPath`), so
/// intermediate values are dropped rather than each scheduling its own `Task`.
private final class SizingLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: String?
    private var scheduled = false

    /// Records `path` as the newest; returns `true` when the caller should
    /// schedule a flush (none is pending), `false` otherwise.
    func stage(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        latest = path
        if scheduled { return false }
        scheduled = true
        return true
    }

    /// Returns the newest staged path and re-arms the scheduler.
    func takeLatest() -> String? {
        lock.lock(); defer { lock.unlock() }
        scheduled = false
        let value = latest
        latest = nil
        return value
    }
}
