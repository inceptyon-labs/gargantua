import Foundation

extension LocalAIService {
    /// Produce advisories for review-tier scan results.
    ///
    /// Iterates `results`, filters to `.review`-tier items (v1 scope — PRD
    /// §2.5 / §6.2 advisory pass targets the ambiguous tier), and asks the
    /// inference engine for a structured suggestion per item. On engine
    /// failure for any item, falls back to a YAML-sourced advisory rather
    /// than throwing — same "always return something" shape as `explain`.
    ///
    /// The safety invariant is owned here: advisories describe what the AI
    /// *thinks* the classification could be (`suggestedSafety`), but this
    /// method never writes back to `ScanResult.safety`. Input `results` are
    /// passed by value (structs are copied) and the caller's array is not
    /// touched.
    ///
    /// - Parameters:
    ///   - results: Scan results to consider. Non-review items are ignored.
    ///   - rules: Map from `ScanResult.id` to the matching `ScanRule`. Items
    ///     without a matching rule are skipped (no YAML fallback text to
    ///     surface).
    /// - Returns: An advisory per eligible review-tier result; empty array
    ///   if nothing qualifies.
    public func advisory(
        for results: [ScanResult],
        rules: [String: ScanRule],
        includeNonReview: Bool = false
    ) async throws -> [ScanResultAdvisory] {
        let eligible = includeNonReview
            ? results.filter { $0.safety != .protected_ }
            : results.filter { $0.safety == .review }
        guard !eligible.isEmpty else { return [] }

        let engine = self.engine
        let stampingSource = sourceForKind(engine.kind)

        if engine.kind == .template {
            return try await templateAdvisories(
                for: eligible,
                rules: rules,
                engine: engine,
                stampingSource: stampingSource
            )
        }

        guard isModelAvailable, await ensureLifecycleReady() else {
            return eligible.compactMap { Self.yamlFallback(for: $0, rules: rules) }
        }

        // Suspend idle timer for the whole batch so a slow engine generating
        // advisories for multiple items can't be unloaded mid-batch. Same
        // pattern as `explain`.
        idleTask?.cancel()
        idleTask = nil
        activeInferenceCount += 1
        defer {
            activeInferenceCount -= 1
            if activeInferenceCount == 0 && lifecycleState == .ready {
                resetIdleTimer()
            }
        }

        return await modelAdvisories(
            for: eligible,
            rules: rules,
            engine: engine,
            stampingSource: stampingSource
        )
    }

    private func templateAdvisories(
        for eligible: [ScanResult],
        rules: [String: ScanRule],
        engine: AIInferenceEngine,
        stampingSource: ExplanationSource
    ) async throws -> [ScanResultAdvisory] {
        var advisories: [ScanResultAdvisory] = []
        for result in eligible {
            guard let rule = rules[result.id] else { continue }
            do {
                let advisory = try await engine.advisory(for: result, rule: rule)
                advisories.append(stampSource(stampingSource, on: advisory))
            } catch {
                if let fallback = Self.yamlFallback(for: result, rules: rules) {
                    advisories.append(fallback)
                }
            }
        }
        return advisories
    }

    private func modelAdvisories(
        for eligible: [ScanResult],
        rules: [String: ScanRule],
        engine: AIInferenceEngine,
        stampingSource: ExplanationSource
    ) async -> [ScanResultAdvisory] {
        var advisories: [ScanResultAdvisory] = []
        for result in eligible {
            guard let rule = rules[result.id] else { continue }
            do {
                let advisory = try await engine.advisory(for: result, rule: rule)
                markFirstInferenceComplete(for: engine.kind)
                advisories.append(stampSource(stampingSource, on: advisory))
            } catch {
                if let fallback = Self.yamlFallback(for: result, rules: rules) {
                    advisories.append(fallback)
                }
            }
        }
        return advisories
    }
}
