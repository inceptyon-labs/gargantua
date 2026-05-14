import Foundation

extension LocalAIService {
    /// Produce a post-cleanup narrative (see `AIServiceProtocol.narrate`).
    /// Non-throwing: any model-availability, load, or engine failure falls
    /// back to the deterministic template so the summary view never has to
    /// render an empty block or an error banner.
    public func narrate(cleanup result: CleanupResult) async -> CleanupNarrative {
        let fallback = CleanupNarrative(
            text: CleanupNarrativeTemplate.text(for: result),
            source: .rule
        )

        let engine = self.engine
        let stampingSource = sourceForKind(engine.kind)

        // Template path: no model required. Run the engine directly so a
        // user-toggled-off session still sees structured `.template` output.
        if engine.kind == .template {
            do {
                let text = try await engine.narrate(cleanup: result)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return fallback }
                return CleanupNarrative(text: trimmed, source: stampingSource)
            } catch {
                return fallback
            }
        }

        guard isModelAvailable else { return fallback }

        if lifecycleState == .unloaded {
            do {
                try await loadModel()
            } catch {
                return fallback
            }
        }

        guard lifecycleState == .ready else { return fallback }

        idleTask?.cancel()
        idleTask = nil
        activeInferenceCount += 1
        defer {
            activeInferenceCount -= 1
            if activeInferenceCount == 0 && lifecycleState == .ready {
                resetIdleTimer()
            }
        }

        do {
            let text = try await engine.narrate(cleanup: result)
            // Empty or whitespace-only engine output is treated as failure —
            // the summary must never render an empty "AI summary" block.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return fallback
            }
            markFirstInferenceComplete(for: engine.kind)
            return CleanupNarrative(text: trimmed, source: stampingSource)
        } catch {
            return fallback
        }
    }

    /// Translate a natural-language query into the allow-listed scan filter DSL.
    ///
    /// The filter is display/control metadata only: it is applied to copies of
    /// scan results in the UI and never writes to `ScanResult.safety`. When the
    /// active engine cannot parse a valid DSL object, returns `nil` so callers
    /// can show a soft "not understood" state.
    public func scanFilter(for query: String) async throws -> ScanFilterSet? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let engine = self.engine
        let engineKind = engine.kind

        func runEngine() async throws -> ScanFilterSet? {
            try await engine.scanFilter(for: trimmed)
        }

        // Template engine doesn't need model weights and the scanFilter path
        // skipped the model gate even before this change. Either way, no
        // load/idle bookkeeping needed.
        if engineKind == .template || !isModelAvailable {
            do {
                return try await runEngine()
            } catch {
                return nil
            }
        }

        if lifecycleState == .unloaded {
            do {
                try await loadModel()
            } catch {
                return nil
            }
        }

        guard lifecycleState == .ready else { return nil }

        idleTask?.cancel()
        idleTask = nil
        activeInferenceCount += 1
        defer {
            activeInferenceCount -= 1
            if activeInferenceCount == 0 && lifecycleState == .ready {
                resetIdleTimer()
            }
        }

        do {
            let filter = try await runEngine()
            // First MLX call may be a natural-language filter resolution; flip
            // the warmup flag so later spinners stop showing the JIT subtitle.
            markFirstInferenceComplete(for: engineKind)
            return filter
        } catch {
            return nil
        }
    }

    /// Run a generic prompt through the active engine for the file
    /// organizer's MLX path. Returns nil when the engine is template-only
    /// (no real model loaded) or when the model isn't available — the
    /// organizer's session state surfaces that as a `.failed` phase with
    /// a guided message. Otherwise loads the model on demand and routes
    /// through `engine.organize`.
    public func organize(prompt: String) async -> String? {
        let engine = self.engine
        let engineKind = engine.kind

        if engineKind == .template || !isModelAvailable {
            return nil
        }

        if lifecycleState == .unloaded {
            do {
                try await loadModel()
            } catch {
                return nil
            }
        }

        guard lifecycleState == .ready else { return nil }

        idleTask?.cancel()
        idleTask = nil
        activeInferenceCount += 1
        defer {
            activeInferenceCount -= 1
            if activeInferenceCount == 0 && lifecycleState == .ready {
                resetIdleTimer()
            }
        }

        do {
            let text = try await engine.organize(prompt: prompt)
            markFirstInferenceComplete(for: engineKind)
            return text
        } catch {
            return nil
        }
    }

    /// Label and classify File Health clusters via the active engine. Returns
    /// an empty array when the engine is template-only, when the model isn't
    /// available, or when the engine response can't be parsed. Mirrors the
    /// lifecycle handling of `scanFilter(for:)` so a long inference can't be
    /// idle-unloaded mid-flight.
    public func suggestClusters(
        _ summaries: [FileHealthClusterSummary]
    ) async -> [FileHealthClusterSuggestion] {
        guard !summaries.isEmpty else { return [] }

        let engine = self.engine
        let engineKind = engine.kind

        if engineKind == .template || !isModelAvailable {
            return (try? await engine.suggestClusters(summaries)) ?? []
        }

        if lifecycleState == .unloaded {
            do {
                try await loadModel()
            } catch {
                return []
            }
        }

        guard lifecycleState == .ready else { return [] }

        idleTask?.cancel()
        idleTask = nil
        activeInferenceCount += 1
        defer {
            activeInferenceCount -= 1
            if activeInferenceCount == 0 && lifecycleState == .ready {
                resetIdleTimer()
            }
        }

        do {
            let suggestions = try await engine.suggestClusters(summaries)
            markFirstInferenceComplete(for: engineKind)
            return suggestions
        } catch {
            return []
        }
    }
}
