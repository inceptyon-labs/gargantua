import Foundation
import MLX
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
// swiftlint:disable type_body_length
// Class wraps lifecycle (load/unload), idle eviction timer, generation,
// and warmup probes; cohesion outweighs file-split benefit. Tracked for
// review under the refactor bean.
@MainActor
public final class MLXInferenceEngine: AIInferenceEngine {
    public let kind: AIEnginePreference = .mlx
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

    public func suggestClusters(
        _ summaries: [FileHealthClusterSummary]
    ) async throws -> [FileHealthClusterSuggestion] {
        guard let modelContainer else {
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
        guard let modelContainer else {
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

    public nonisolated static let cleanupNarrativeInstructions = """
    You are a helpful assistant that summarizes a completed macOS cleanup \
    in 1 to 2 short sentences. Describe what was cleaned and any notable \
    groupings. Plain English only — no bullet lists, no code fences, no \
    markdown headers. Do not invent items, paths, or numbers that are \
    not in the provided summary.
    """

    public nonisolated static let clusterSuggestionInstructions = """
    You label and classify groups of files for a macOS cleanup tool. \
    Every group is identified by a path prefix and described by a category, \
    sample paths, count, and total size. For each group, return a short \
    human label, a safety classification, and one short sentence of rationale. \
    Output JSON only — an array under key "suggestions" — with keys: \
    cluster_id (the exact prefix as given), label (3-6 words, no quotes), \
    safety (one of "safe", "review", "protected"), rationale (one short sentence). \
    safety must be conservative: only mark groups "safe" when the sample paths \
    clearly point to regenerable build, cache, or temp output.
    """

    public nonisolated static let scanFilterInstructions = """
    You translate one user query into a strict JSON object for filtering \
    macOS cleanup scan results. Output JSON only. Allowed keys are: \
    bundle_ids (array of strings), path_globs (array of glob strings), \
    categories (array of strings), min_size (integer bytes), max_size \
    (integer bytes), safety (array containing safe, review, or protected). \
    Do not emit any other keys.
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

    /// Build the prompt body for `suggestClusters`. One JSON-shaped block per
    /// summary, capped sample paths at five each so the prompt stays under a
    /// few thousand tokens even for tabs with hundreds of clusters. Sample
    /// paths are sanitized (control chars stripped, length capped) so a
    /// hostile filename can't smuggle a new instruction into the model.
    static func buildClusterSuggestionPrompt(
        for summaries: [FileHealthClusterSummary]
    ) -> String {
        var lines: [String] = []
        lines.append("Groups to classify:")
        lines.append("")
        for summary in summaries {
            lines.append("- cluster_id: \(sanitizeForPrompt(summary.id))")
            lines.append("  category: \(sanitizeForPrompt(summary.category))")
            lines.append("  count: \(summary.count)")
            lines.append("  total_size: \(ByteCountFormatter.string(fromByteCount: summary.totalSize, countStyle: .file))")
            if !summary.samplePaths.isEmpty {
                lines.append("  sample_paths:")
                for path in summary.samplePaths.prefix(5) {
                    lines.append("    - \(sanitizeForPrompt(path))")
                }
            }
        }
        lines.append("")
        lines.append("Return JSON only, with shape: {\"suggestions\":[{\"cluster_id\":\"…\",\"label\":\"…\",\"safety\":\"safe|review|protected\",\"rationale\":\"…\"}]}.")
        return lines.joined(separator: "\n")
    }

    /// Parse a JSON response from `suggestClusters` into typed suggestions.
    /// Lenient by design — small local models drift on shape and formatting,
    /// so the parser:
    ///   * accepts both `{"suggestions": [...]}` and a bare top-level `[...]`
    ///   * normalizes cluster ids on both sides (lowercase, strip ~/, strip
    ///     expanded home prefix, drop leading/trailing slashes) so the model
    ///     can echo `/Users/Jason/X/Y` when we asked for `~/X/Y/` and still
    ///     match the canonical id.
    ///   * silently drops entries with unrecognized safety values or that
    ///     reference a cluster id we never sent.
    static func parseClusterSuggestions(
        _ response: String,
        allowed: [FileHealthClusterSummary]
    ) -> [FileHealthClusterSuggestion] {
        guard let raw = extractSuggestionEntries(from: response) else {
            return []
        }

        // Build normalized -> canonical lookup so the model can deviate on
        // formatting and we still find the right cluster.
        let lookup: [String: String] = Dictionary(
            allowed.map { (normalizeClusterID($0.id), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        var seen: Set<String> = []
        var out: [FileHealthClusterSuggestion] = []
        for entry in raw {
            guard let modelClusterID = entry["cluster_id"] as? String,
                  let canonical = lookup[normalizeClusterID(modelClusterID)],
                  !seen.contains(canonical),
                  let label = entry["label"] as? String,
                  let safetyString = entry["safety"] as? String,
                  let safety = parseSafety(safetyString)
            else { continue }
            let rationale = (entry["rationale"] as? String) ?? ""
            seen.insert(canonical)
            out.append(FileHealthClusterSuggestion(
                clusterID: canonical,
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                safety: safety,
                rationale: rationale.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return out
    }

    /// Normalize a cluster id for tolerant matching. Lowercases, strips
    /// surrounding whitespace, removes a leading `~/` or expanded home path,
    /// and drops surrounding slashes. The result is purely a comparison
    /// token — never used as a real path.
    static func normalizeClusterID(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("~/") { s = String(s.dropFirst(2)) }
        let expandedHome = NSString(string: "~").expandingTildeInPath.lowercased() + "/"
        if s.hasPrefix(expandedHome) { s = String(s.dropFirst(expandedHome.count)) }
        while s.hasPrefix("/") { s = String(s.dropFirst()) }
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

    /// Pull the suggestion entries out of the model response, accepting
    /// either `{"suggestions": [...]}` or a bare top-level `[...]`.
    private static func extractSuggestionEntries(from response: String) -> [[String: Any]]? {
        // Try object shape first.
        if let json = extractFirstJSONObject(from: response),
           let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = parsed["suggestions"] as? [[String: Any]]
        {
            return raw
        }
        // Fall back to bare-array shape.
        if let array = extractFirstJSONArray(from: response),
           let data = array.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        {
            return parsed
        }
        return nil
    }

    /// Same balanced-scan as `extractFirstJSONObject`, but for `[...]`. Used
    /// when the model emits the suggestions array without the object wrapper.
    static func extractFirstJSONArray(from text: String) -> String? {
        guard let start = text.firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escaping = false
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if escaping {
                escaping = false
            } else if inString {
                if c == "\\" { escaping = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "[": depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 {
                        return String(text[start ... i])
                    }
                default: break
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func parseSafety(_ raw: String) -> SafetyLevel? {
        switch raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "safe": return .safe
        case "review": return .review
        case "protected", "protected_": return .protected_
        default: return nil
        }
    }

    /// Find the first balanced `{...}` block in a string, ignoring leading
    /// prose, trailing commentary, or markdown fences. Used by the cluster
    /// suggestion parser; the model wraps JSON in code fences from time to
    /// time even with strict instructions.
    static func extractFirstJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaping = false
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if escaping {
                escaping = false
            } else if inString {
                if c == "\\" { escaping = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(text[start ... i])
                    }
                default: break
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    static func buildScanFilterPrompt(for query: String) -> String {
        let sanitized = sanitizeForPrompt(query)
        return """
        Query: \(sanitized)

        Return the smallest filter that matches the query. Use known \
        categories such as dev_artifacts, docker, homebrew, browser_cache, \
        system_logs, system_temp, installers, duplicate_files, and \
        big_files when applicable. If no safe filter is implied, return {}.
        """
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
        let methodLabel = switch result.cleanupMethod {
        case .trash: "moved to Trash"
        case .delete: "permanently deleted"
        case .toolNative: "cleaned by tool"
        }
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
