import Foundation
import MLXLLM
import MLXLMCommon
import OSLog

private let mlxLogger = Logger(subsystem: "com.gargantua.core", category: "MLXInferenceEngine")

/// Errors specific to `MLXInferenceEngine`. `LocalAIService` wraps load-time
/// errors in `AIServiceError.loadFailed`; generate-time errors are caught and
/// the caller falls back to the YAML rule explanation.
public enum MLXInferenceError: Error, LocalizedError {
    /// The supplied path does not resolve to a directory on disk.
    case modelPathIsNotDirectory(String)
    /// The directory is missing files MLX LM needs to load a model.
    case modelDirectoryIncomplete(directory: String, missing: [String])
    /// The engine was asked to generate before a successful `load`.
    case notLoaded
    /// Chat-template rendering produced no tokens (unexpected upstream behavior).
    case emptyPrompt

    public var errorDescription: String? {
        switch self {
        case .modelPathIsNotDirectory(let path):
            return "Model path \(path) is not a directory. MLX LM expects a directory containing config.json + tokenizer.json + *.safetensors."
        case .modelDirectoryIncomplete(let directory, let missing):
            return "Model directory \(directory) is missing required files: \(missing.joined(separator: ", "))."
        case .notLoaded:
            return "MLX inference engine cannot generate before a successful load."
        case .emptyPrompt:
            return "Chat template rendered an empty token sequence."
        }
    }
}

/// MLX Swift-backed inference engine. Loads a quantized decoder-only LLM from
/// a local directory (the `ModelDownloadManager` stages one), formats a prompt
/// from the rule/result, and generates a short advisory explanation.
///
/// `load(modelPath:modelSize:)` interprets `modelPath` as a directory URL
/// (either the directory itself or a file inside it — the file's parent is
/// used). `modelSize` from the protocol is the on-disk size; actual resident
/// bytes are read from `MLX.Memory.activeMemory` post-load so the 3 GB guard
/// in `LocalAIService` sees a real number rather than the compressed size.
///
/// `generate(for:rule:)` builds a short "you are a helpful cleanup explainer"
/// chat turn, runs it through `ChatSession`, and returns the full response.
/// Generation parameters are tuned for short advisory text: low temperature,
/// capped at a handful of sentences.
@MainActor
public final class MLXInferenceEngine: AIInferenceEngine {
    public let kind: AIEnginePreference = .mlx

    public var isLoaded: Bool { lifecycle.isLoaded }
    public var memoryUsage: Int64 { lifecycle.memoryUsage }

    private let lifecycle = MLXLifecycleController()

    /// Max new tokens per generate call. ~180 tokens ≈ 3–5 sentences.
    public let maxNewTokens: Int

    /// Sampling temperature. 0.3 gives stable advisory text.
    public let temperature: Float

    /// Optional system instructions prepended to every chat turn.
    public let instructions: String

    public init(
        maxNewTokens: Int = 180,
        temperature: Float = 0.3,
        instructions: String = MLXInferenceEngine.defaultInstructions
    ) {
        self.maxNewTokens = maxNewTokens
        self.temperature = temperature
        self.instructions = instructions
    }

    // MARK: - AIInferenceEngine

    public func load(modelPath: String, modelSize _: Int64) async throws {
        try await lifecycle.load(modelPath: modelPath)
    }

    public func unload() {
        lifecycle.unload()
    }

    public func generate(for result: ScanResult, rule: ScanRule) async throws -> String {
        guard let modelContainer = lifecycle.modelContainer else {
            throw MLXInferenceError.notLoaded
        }

        let prompt = Self.buildPrompt(for: result, rule: rule)
        let session = ChatSession(
            modelContainer,
            instructions: instructions,
            generateParameters: GenerateParameters(
                maxTokens: maxNewTokens,
                temperature: temperature
            )
        )
        return try await session.respond(to: prompt)
    }

    public func narrate(cleanup result: CleanupResult) async throws -> String {
        guard let modelContainer = lifecycle.modelContainer else {
            throw MLXInferenceError.notLoaded
        }

        let prompt = Self.buildCleanupPrompt(for: result)
        let session = ChatSession(
            modelContainer,
            instructions: Self.cleanupNarrativeInstructions,
            generateParameters: GenerateParameters(
                maxTokens: 120,
                temperature: temperature
            )
        )
        return try await session.respond(to: prompt)
    }

    public func suggestClusters(
        _ summaries: [FileHealthClusterSummary]
    ) async throws -> [FileHealthClusterSuggestion] {
        guard let modelContainer = lifecycle.modelContainer else {
            throw MLXInferenceError.notLoaded
        }
        guard !summaries.isEmpty else { return [] }

        let session = ChatSession(
            modelContainer,
            instructions: Self.clusterSuggestionInstructions,
            generateParameters: GenerateParameters(
                maxTokens: 768,
                temperature: 0.2
            )
        )
        let response = try await session.respond(to: Self.buildClusterSuggestionPrompt(for: summaries))
        let suggestions = Self.parseClusterSuggestions(response, allowed: summaries)
        if suggestions.isEmpty {
            // Log a truncated response so the next operator can see what the
            // model actually emitted when the parser declined to use it.
            // Captured at .info so it doesn't pollute typical logs but stays
            // available via `log show --predicate ...`.
            let preview = response.prefix(800)
            mlxLogger.info("suggestClusters parsed 0 entries from response (first 800 chars): \(preview, privacy: .public)")
        }
        return suggestions
    }

    public func scanFilter(for query: String) async throws -> ScanFilterSet? {
        guard let modelContainer = lifecycle.modelContainer else {
            throw MLXInferenceError.notLoaded
        }

        let session = ChatSession(
            modelContainer,
            instructions: Self.scanFilterInstructions,
            generateParameters: GenerateParameters(
                maxTokens: 160,
                temperature: 0.1
            )
        )
        let response = try await session.respond(to: Self.buildScanFilterPrompt(for: query))
        return ScanFilterSet.decodeAllowListed(from: response)
    }

    /// Run a generic prompt through the loaded model and return its raw
    /// text response. Provides a low-level entry point for callers that
    /// need to build their own prompt + parser stack on top of MLX (e.g.
    /// the file organizer's MLXOrganizerProposer). Token budget is 1024
    /// — generous for structured JSON output without blowing memory on
    /// 1B-class models.
    public func organize(prompt: String) async throws -> String {
        guard let modelContainer = lifecycle.modelContainer else {
            throw MLXInferenceError.notLoaded
        }
        let session = ChatSession(
            modelContainer,
            instructions: Self.organizerInstructions,
            generateParameters: GenerateParameters(
                maxTokens: 1_024,
                temperature: 0.1
            )
        )
        return try await session.respond(to: prompt)
    }

    private static let organizerInstructions = """
    You are a file organization assistant. Read a folder listing the user provides \
    and return strict JSON describing how to group the files into subfolders. \
    Never include prose, never wrap the JSON in markdown fences, and never \
    invent file ids that were not in the input.
    """
}
