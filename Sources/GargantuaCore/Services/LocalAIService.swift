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

    /// Maximum allowed model memory in bytes (3 GB).
    public static let maxModelMemory: Int64 = 3_000_000_000

    /// Seconds of inactivity before auto-unloading the model.
    public let idleTimeout: TimeInterval

    private let downloadManager: ModelDownloadManager
    private let engine: AIInferenceEngine
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

    public func explain(result: ScanResult, rule: ScanRule) async throws -> AIExplanation {
        // Fallback: no model on disk → return YAML rule explanation
        guard isModelAvailable else {
            return AIExplanation(text: rule.explanation, source: .rule)
        }

        // Lazy load
        if lifecycleState == .unloaded {
            try await loadModel()
        }

        // Guard: if loading failed or model too large, fall back
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
            return AIExplanation(text: text, source: .ai)
        } catch {
            // Engine failure is advisory — surface the YAML rule rather than
            // throwing, so callers always get a usable explanation.
            return AIExplanation(text: rule.explanation, source: .rule)
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
