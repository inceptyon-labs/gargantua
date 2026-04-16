import Foundation

/// On-device AI service using lazy model loading with automatic idle unloading.
///
/// Loads the model into memory on first `explain` call, then starts a 60-second
/// idle timer. If no further calls arrive within that window, the model is
/// unloaded to free RAM. Each `explain` call resets the timer.
///
/// When no model file is available on disk, `explain` returns the YAML rule's
/// built-in explanation string instead.
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
    private var modelData: Data?
    private var idleTask: Task<Void, Never>?

    /// Creates a new LocalAIService.
    ///
    /// - Parameters:
    ///   - downloadManager: Provides model file path and download state.
    ///   - idleTimeout: Seconds before auto-unload (default: 60).
    public init(downloadManager: ModelDownloadManager, idleTimeout: TimeInterval = 60) {
        self.downloadManager = downloadManager
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

        resetIdleTimer()

        let explanation = generateExplanation(for: result, rule: rule)
        return AIExplanation(text: explanation, source: .ai)
    }

    public func unloadModel() {
        idleTask?.cancel()
        idleTask = nil
        modelData = nil
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
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            modelData = data
            modelMemoryUsage = Int64(data.count)
            lifecycleState = .ready
        } catch {
            modelData = nil
            modelMemoryUsage = 0
            lifecycleState = .unloaded
            throw AIServiceError.loadFailed(underlying: error)
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

    /// Placeholder inference — returns a structured explanation using rule metadata.
    ///
    /// Replace this method body with actual MLX Swift inference when the
    /// framework dependency is added.
    private func generateExplanation(for result: ScanResult, rule: ScanRule) -> String {
        // TODO: Replace with MLX inference when framework is available
        var parts: [String] = []
        parts.append("\(result.name) is a \(rule.category.replacingOccurrences(of: "_", with: " ")) item")
        parts.append("created by \(result.source.name).")

        if result.regenerates {
            if let cmd = result.regenerateCommand {
                parts.append("It can be regenerated with `\(cmd)`.")
            } else {
                parts.append("It regenerates automatically.")
            }
        }

        parts.append("Safety: \(result.safety.rawValue) (\(result.confidence)% confidence).")
        parts.append(rule.explanation)

        return parts.joined(separator: " ")
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
