import Foundation
import MLX
import MLXLLM
import MLXLMCommon

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
    public private(set) var isLoaded: Bool = false
    public private(set) var memoryUsage: Int64 = 0

    private var modelContainer: ModelContainer?
    private var baselineActiveMemory: Int = 0

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

    public nonisolated static let defaultInstructions = """
        You are a helpful assistant that explains macOS cleanup items to end users. \
        Given a scanned item's metadata, explain in plain English what it is, whether \
        it is safe to delete, and any caveats. Be concise — 2 to 4 short sentences. \
        Do not include code fences, bullet lists, or markdown headers.
        """

    // MARK: - AIInferenceEngine

    public func load(modelPath: String, modelSize _: Int64) async throws {
        let directory = try Self.resolveModelDirectory(modelPath)
        try Self.validateModelDirectory(directory)

        // Record baseline so memoryUsage reflects just this engine's weights.
        let baseline = MLX.Memory.activeMemory
        baselineActiveMemory = baseline

        let tokenizerLoader = SwiftTransformersTokenizerLoader()
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: tokenizerLoader
        )

        modelContainer = container
        let after = MLX.Memory.activeMemory
        memoryUsage = Int64(max(0, after - baseline))
        isLoaded = true
    }

    public func unload() {
        let wasLoaded = isLoaded
        modelContainer = nil
        // Return cached buffers to the system allocator — without this,
        // `MLX.Memory.activeMemory` would still report the pool even after
        // weights are dropped, and the 60 s idle-unload would look like it did
        // nothing. Skip when the engine was never loaded: that path touches
        // MLX and forces Metal device init, which fails until the release
        // pipeline ships a compiled `default.metallib`.
        if wasLoaded {
            MLX.Memory.clearCache()
        }
        memoryUsage = 0
        isLoaded = false
    }

    public func generate(for result: ScanResult, rule: ScanRule) async throws -> String {
        guard let modelContainer else {
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
        guard let modelContainer else {
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

    public nonisolated static let cleanupNarrativeInstructions = """
        You are a helpful assistant that summarizes a completed macOS cleanup \
        in 1 to 2 short sentences. Describe what was cleaned and any notable \
        groupings. Plain English only — no bullet lists, no code fences, no \
        markdown headers. Do not invent items, paths, or numbers that are \
        not in the provided summary.
        """

    // MARK: - Prompt

    /// Builds the user-turn content for `generate`. Pulled out so tests can
    /// pin the shape without spinning up a model.
    static func buildPrompt(for result: ScanResult, rule: ScanRule) -> String {
        var lines: [String] = []
        lines.append("Item: \(result.name)")
        lines.append("Path: \(result.path)")
        lines.append("Category: \(rule.category.replacingOccurrences(of: "_", with: " "))")
        lines.append("Source app: \(result.source.name)")
        lines.append("Size: \(ByteCountFormatter.string(fromByteCount: result.size, countStyle: .file))")
        lines.append("Safety classification (from YAML rule): \(result.safety.rawValue) (\(result.confidence)% confidence)")
        if result.regenerates {
            if let cmd = result.regenerateCommand {
                lines.append("Regenerates: yes, via `\(cmd)`")
            } else {
                lines.append("Regenerates: yes, automatically")
            }
        } else {
            lines.append("Regenerates: no")
        }
        lines.append("Rule explanation (canonical, do not contradict): \(rule.explanation)")
        lines.append("")
        lines.append("Explain what this item is and whether it is safe to delete.")
        return lines.joined(separator: "\n")
    }

    /// Max characters kept when interpolating a scan-result name into the
    /// cleanup-narrative prompt. Longer names are truncated with an ellipsis.
    static let maxPromptNameLength = 64

    /// Collapse whitespace/control characters and truncate to
    /// `maxPromptNameLength`. Defends against filenames containing newlines
    /// or instruction-like text that would otherwise hijack the model prompt.
    static func sanitizeForPrompt(_ input: String) -> String {
        let collapsed = input
            .unicodeScalars
            .map { scalar -> Character in
                if scalar.properties.generalCategory == .control || scalar == "\n" || scalar == "\r" {
                    return " "
                }
                return Character(scalar)
            }
        var s = String(collapsed)
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > maxPromptNameLength {
            s = String(s.prefix(maxPromptNameLength)) + "…"
        }
        return s
    }

    /// Build the cleanup-narrative prompt from aggregated `CleanupResult`
    /// fields only. Individual item paths are intentionally omitted — the
    /// model sees item *names* (already in the result, already shown in the
    /// summary card), counts, and byte totals. This keeps the narrative from
    /// surfacing PII beyond what the user can already see in the card.
    static func buildCleanupPrompt(for result: CleanupResult) -> String {
        var lines: [String] = []
        let methodLabel = result.cleanupMethod == .trash ? "moved to Trash" : "permanently deleted"
        lines.append("Cleanup method: \(methodLabel)")
        lines.append("Items succeeded: \(result.succeededItems.count)")
        lines.append("Items failed: \(result.failedItems.count)")
        let freed = ByteCountFormatter.string(fromByteCount: result.totalFreed, countStyle: .file)
        lines.append("Total freed: \(freed)")

        let groups = CleanupNarrativeTemplate.groupSucceededItems(in: result)
        if !groups.isEmpty {
            lines.append("Top groups cleaned:")
            for group in groups.prefix(5) {
                let bytes = ByteCountFormatter.string(fromByteCount: group.bytes, countStyle: .file)
                // Names come from YAML-rule matches but can technically be any
                // string — collapse control characters and cap length so a
                // hostile filename can't inject extra prompt bullets or new
                // instructions.
                let safeName = sanitizeForPrompt(group.name)
                lines.append("- \(safeName): \(group.count) items, \(bytes)")
            }
        }

        lines.append("")
        lines.append(
            "Write 1 to 2 short sentences describing what was cleaned. " +
            "Use only the numbers above; do not invent item names, paths, or sizes."
        )
        return lines.joined(separator: "\n")
    }

    // MARK: - Directory resolution

    /// Accepts either a directory path or a file path (whose parent is used).
    /// `ModelDownloadManager` currently stages a single file; that file's
    /// parent directory is not itself a HF-layout model root, so today this
    /// path will fail validation — a planned follow-up reworks the manager.
    static func resolveModelDirectory(_ modelPath: String) throws -> URL {
        let url = URL(fileURLWithPath: modelPath)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else {
            throw MLXInferenceError.modelPathIsNotDirectory(modelPath)
        }
        if isDirectory.boolValue {
            return url
        }
        // A file was passed — use its parent directory.
        return url.deletingLastPathComponent()
    }

    /// Confirms the directory contains the minimum files MLX LM needs.
    static func validateModelDirectory(_ directory: URL) throws {
        // `config.json` is mandatory; MLX LM decodes the architecture from it.
        // `tokenizer.json` (or tokenizer_config.json) is needed by
        // swift-transformers' AutoTokenizer.
        // At least one weights file (`.safetensors`) must be present.
        let fm = FileManager.default
        var missing: [String] = []
        if !fm.fileExists(atPath: directory.appendingPathComponent("config.json").path) {
            missing.append("config.json")
        }
        let tokenizerJSON = directory.appendingPathComponent("tokenizer.json").path
        let tokenizerConfig = directory.appendingPathComponent("tokenizer_config.json").path
        if !fm.fileExists(atPath: tokenizerJSON) && !fm.fileExists(atPath: tokenizerConfig) {
            missing.append("tokenizer.json or tokenizer_config.json")
        }
        if let contents = try? fm.contentsOfDirectory(atPath: directory.path) {
            if !contents.contains(where: { $0.hasSuffix(".safetensors") }) {
                missing.append("*.safetensors")
            }
        } else {
            missing.append("*.safetensors")
        }
        guard missing.isEmpty else {
            throw MLXInferenceError.modelDirectoryIncomplete(
                directory: directory.path,
                missing: missing
            )
        }
    }
}
