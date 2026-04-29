import Foundation

/// On-device AI service using lazy model loading with automatic idle unloading.
///
/// Loads the model into memory on first `explain` call, then starts a 60-second
/// idle timer. If no further calls arrive within that window, the model is
/// unloaded to free RAM. Each `explain` call resets the timer.
///
/// When no model file is available on disk, `explain` returns the YAML rule's
/// built-in explanation string instead.
///
/// The actual text generation is delegated to an injected
/// `AIInferenceEngine`. The default engine (`TemplateInferenceEngine`)
/// produces deterministic structured text; swapping in an MLX-backed engine
/// replaces it with real model output without changing this class.
@MainActor
public final class LocalAIService: ObservableObject, AIServiceProtocol {
    /// Current lifecycle state of the model.
    @Published public private(set) var lifecycleState: AIModelLifecycleState = .unloaded

    /// Approximate memory used by the loaded model, in bytes.
    @Published public private(set) var modelMemoryUsage: Int64 = 0

    /// Flips true the first time an MLX-backed inference returns successfully
    /// in this session and stays true until the engine is reconfigured. The UI
    /// reads this to decide whether to surface the "Compiling shaders for
    /// first use…" subtitle on its loading spinners — that latency only hits
    /// the very first call after the GPU JIT-compiles its kernels.
    @Published public private(set) var hasCompletedFirstMLXInference: Bool = false

    /// Maximum allowed model memory in bytes (3 GB).
    public static let maxModelMemory: Int64 = 3_000_000_000

    /// Seconds of inactivity before auto-unloading the model.
    public let idleTimeout: TimeInterval

    private let downloadManager: ModelDownloadManager
    private var engine: AIInferenceEngine
    private var idleTask: Task<Void, Never>?
    private var activeInferenceCount: Int = 0

    /// Creates a new LocalAIService.
    ///
    /// - Parameters:
    ///   - downloadManager: Provides model file path and download state.
    ///   - engine: Backend that runs inference. Defaults to
    ///     `TemplateInferenceEngine`, which produces deterministic
    ///     structured text from rule/result metadata.
    ///   - idleTimeout: Seconds before auto-unload (default: 60).
    public init(
        downloadManager: ModelDownloadManager,
        engine: AIInferenceEngine? = nil,
        idleTimeout: TimeInterval = 60
    ) {
        self.downloadManager = downloadManager
        self.engine = engine ?? TemplateInferenceEngine()
        self.idleTimeout = idleTimeout
    }

    // MARK: - AIServiceProtocol

    public var isModelAvailable: Bool {
        if case .downloaded = downloadManager.state {
            return true
        }
        return false
    }

    /// Replace the inference backend after a settings change or model-state
    /// transition. Existing model state is unloaded first so the new backend
    /// starts from a clean lifecycle. The first-MLX-inference flag is also
    /// cleared so a switch from Template → MLX (or MLX reload) re-shows the
    /// "compiling shaders" subtitle on the next call.
    public func configureEngine(_ newEngine: AIInferenceEngine) {
        unloadModel()
        engine = newEngine
        hasCompletedFirstMLXInference = false
    }

    public func explain(result: ScanResult, rule: ScanRule) async throws -> AIExplanation {
        // Capture the engine + its source label up front. A settings change
        // mid-call (`configureEngine`) replaces `self.engine`, but inference
        // already in flight should be labeled and accounted against the
        // engine that actually produced it.
        let engine = self.engine
        let stampingSource = sourceForKind(engine.kind)

        // Template engine doesn't need model weights — it stitches rule +
        // scan metadata. Run it directly so "AI Off" produces honest
        // `.template` output instead of falling back to raw YAML.
        if engine.kind == .template {
            do {
                let text = try await engine.generate(for: result, rule: rule)
                return AIExplanation(text: text, source: stampingSource)
            } catch {
                return AIExplanation(text: rule.explanation, source: .rule)
            }
        }

        // MLX path: needs a downloaded model, lazy-load + ready guards apply.
        guard isModelAvailable else {
            return AIExplanation(text: rule.explanation, source: .rule)
        }

        if lifecycleState == .unloaded {
            do {
                try await loadModel()
            } catch {
                return AIExplanation(text: rule.explanation, source: .rule)
            }
        }

        guard lifecycleState == .ready else {
            return AIExplanation(text: rule.explanation, source: .rule)
        }

        // Suspend the idle timer while inference is in flight so a long
        // generation on a real MLX backend cannot be unloaded mid-call.
        // The timer is restarted once no inference is active.
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
            let text = try await engine.generate(for: result, rule: rule)
            markFirstInferenceComplete(for: engine.kind)
            return AIExplanation(text: text, source: stampingSource)
        } catch {
            return AIExplanation(text: rule.explanation, source: .rule)
        }
    }

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
        rules: [String: ScanRule]
    ) async throws -> [ScanResultAdvisory] {
        let reviewOnly = results.filter { $0.safety == .review }
        guard !reviewOnly.isEmpty else { return [] }

        func yamlFallback(for result: ScanResult) -> ScanResultAdvisory? {
            guard let rule = rules[result.id] else { return nil }
            return ScanResultAdvisory(
                resultId: result.id,
                rationale: rule.explanation,
                suggestedSafety: result.safety,
                source: .rule
            )
        }

        let engine = self.engine
        let stampingSource = sourceForKind(engine.kind)

        // Template path: no model required.
        if engine.kind == .template {
            var advisories: [ScanResultAdvisory] = []
            for result in reviewOnly {
                guard let rule = rules[result.id] else { continue }
                do {
                    let advisory = try await engine.advisory(for: result, rule: rule)
                    advisories.append(stampSource(stampingSource, on: advisory))
                } catch {
                    if let fallback = yamlFallback(for: result) {
                        advisories.append(fallback)
                    }
                }
            }
            return advisories
        }

        guard isModelAvailable else {
            return reviewOnly.compactMap(yamlFallback)
        }

        if lifecycleState == .unloaded {
            do {
                try await loadModel()
            } catch {
                return reviewOnly.compactMap(yamlFallback)
            }
        }

        guard lifecycleState == .ready else {
            return reviewOnly.compactMap(yamlFallback)
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

        var advisories: [ScanResultAdvisory] = []
        for result in reviewOnly {
            guard let rule = rules[result.id] else { continue }
            do {
                let advisory = try await engine.advisory(for: result, rule: rule)
                markFirstInferenceComplete(for: engine.kind)
                advisories.append(stampSource(stampingSource, on: advisory))
            } catch {
                if let fallback = yamlFallback(for: result) {
                    advisories.append(fallback)
                }
            }
        }
        return advisories
    }

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

    public func unloadModel() {
        idleTask?.cancel()
        idleTask = nil
        engine.unload()
        modelMemoryUsage = 0
        lifecycleState = .unloaded
    }

    // MARK: - Private

    private func loadModel() async throws {
        guard case .downloaded(let path, let size) = downloadManager.state else {
            return
        }

        // RAM guard: refuse to load models over 3 GB
        guard size <= Self.maxModelMemory else {
            throw AIServiceError.modelTooLarge(size: size, limit: Self.maxModelMemory)
        }

        lifecycleState = .loading

        do {
            try await engine.load(modelPath: path, modelSize: size)
        } catch {
            engine.unload()
            modelMemoryUsage = 0
            lifecycleState = .unloaded
            throw AIServiceError.loadFailed(underlying: error)
        }

        // Resident-memory guard: on-disk size is pre-validated, but a real
        // backend may decompress or expand weights in memory. Refuse if the
        // engine's reported memory exceeds the RAM limit.
        let resident = engine.memoryUsage
        if resident > Self.maxModelMemory {
            engine.unload()
            modelMemoryUsage = 0
            lifecycleState = .unloaded
            throw AIServiceError.modelTooLarge(size: resident, limit: Self.maxModelMemory)
        }

        modelMemoryUsage = resident
        lifecycleState = .ready
    }

    /// Map an engine kind to the `ExplanationSource` the UI should display.
    /// Callers capture this once before awaiting so a concurrent
    /// `configureEngine` swap can't relabel the result of an in-flight call.
    private func sourceForKind(_ kind: AIEnginePreference) -> ExplanationSource {
        switch kind {
        case .mlx: return .ai
        case .template: return .template
        }
    }

    /// Rebuild an advisory with the active engine's source. Engines may stamp
    /// `.ai` themselves (the protocol's default extension does), so the
    /// service has the final say to keep labeling consistent across calls.
    private func stampSource(
        _ source: ExplanationSource,
        on advisory: ScanResultAdvisory
    ) -> ScanResultAdvisory {
        guard advisory.source != source else { return advisory }
        return ScanResultAdvisory(
            resultId: advisory.resultId,
            rationale: advisory.rationale,
            suggestedSafety: advisory.suggestedSafety,
            source: source
        )
    }

    /// Flip the warmup flag once an MLX-backed call returns successfully.
    /// Takes the captured engine kind so a concurrent settings change
    /// (`configureEngine` swapped `self.engine` mid-call) doesn't mislabel.
    private func markFirstInferenceComplete(for kind: AIEnginePreference) {
        guard !hasCompletedFirstMLXInference else { return }
        if kind == .mlx {
            hasCompletedFirstMLXInference = true
        }
    }

    private func resetIdleTimer() {
        idleTask?.cancel()
        idleTask = Task { [weak self, idleTimeout] in
            try? await Task.sleep(for: .seconds(idleTimeout))
            guard !Task.isCancelled else { return }
            self?.unloadModel()
        }
    }
}

/// Errors specific to the AI service.
public enum AIServiceError: Error, LocalizedError {
    /// Model file exceeds the RAM limit.
    case modelTooLarge(size: Int64, limit: Int64)
    /// Failed to load model data from disk.
    case loadFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .modelTooLarge(let size, let limit):
            let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .memory)
            let limitStr = ByteCountFormatter.string(fromByteCount: limit, countStyle: .memory)
            return "Model size (\(sizeStr)) exceeds limit (\(limitStr))"
        case .loadFailed(let error):
            return "Failed to load AI model: \(error.localizedDescription)"
        }
    }
}
