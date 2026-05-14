import Foundation
import OSLog

private let mlxOrganizerLogger = Logger(
    subsystem: "com.gargantua.core",
    category: "MLXOrganizerProposer"
)

/// File-organization proposer routed through the user's downloaded MLX
/// model. Uses an MLX-specific prompt (simpler than the Cloud schema,
/// includes a one-shot example) plus a lenient parser tuned for the
/// 1B-class output drift the Llama 3.2 1B model exhibits:
///   * Strips markdown code fences before extracting JSON.
///   * Accepts either `{"plans":[...]}` or a bare `[...]` at the top
///     level (the model sometimes drops the wrapper).
///   * Falls back to the Cloud parser's reassembly pipeline so the
///     opaque-ID + validate() safety net still applies regardless of
///     which AI produced the proposal.
///
/// Raw model output is logged (truncated) on parse failure so future
/// iteration has data — small local models are unreliable on strict
/// JSON and the parser will sometimes lose; users get a guided error
/// pointing them at Cloud / Claude Code as the reliable alternative.
@MainActor
public final class MLXOrganizerProposer {
    private let aiService: LocalAIService
    private let now: @MainActor () -> Date
    private let fileManager: FileManager

    public init(
        aiService: LocalAIService,
        now: @MainActor @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.aiService = aiService
        self.now = now
        self.fileManager = fileManager
    }

    public func propose(sourceFolder: URL) async throws -> OrganizationProposal {
        let listing = try CloudOrganizerProposer.listFolder(at: sourceFolder, fileManager: fileManager)
        let prompt = Self.buildSmallModelPrompt(
            folderName: sourceFolder.lastPathComponent,
            items: listing
        )
        guard let raw = await aiService.organize(prompt: prompt) else {
            throw MLXOrganizerError.modelNotLoaded
        }

        guard let extracted = Self.extractJSON(from: raw) else {
            mlxOrganizerLogger.info(
                "MLX organize returned no parseable JSON (first 1500 chars): \(raw.prefix(1_500), privacy: .public)"
            )
            throw MLXOrganizerError.unparseableResponse(underlying: "no JSON object or array found")
        }

        do {
            return try CloudOrganizerProposer.parseResponse(
                text: extracted,
                sourceFolder: sourceFolder,
                listing: listing,
                generatedAt: now()
            )
        } catch {
            let errString = String(describing: error)
            mlxOrganizerLogger.info(
                "MLX organize JSON parsed but reassembly failed (\(errString, privacy: .public)) raw=\(raw.prefix(1_500), privacy: .public)"
            )
            throw MLXOrganizerError.unparseableResponse(underlying: errString)
        }
    }

    // MARK: - Small-model prompt

    /// One-shot prompt tuned for Llama-3.2-1B-class quants. Includes a
    /// worked example so the model stays on the JSON-out rails — without
    /// the example, 1B models drift into prose or YAML 80%+ of the time.
    static func buildSmallModelPrompt(
        folderName: String,
        items: [CloudOrganizerProposer.FolderListingItem]
    ) -> String {
        let examplePrompt = """
        Folder: ExampleFolder
        Files:
        - a1: receipt-jan.pdf
        - a2: receipt-feb.pdf
        - b1: photo1.jpg
        - b2: photo2.jpg
        """
        let exampleAnswer = """
        {"plans":[\
        {"name":"Receipts","reasoning":"PDFs that look like receipts","item_ids":["a1","a2"]},\
        {"name":"Photos","reasoning":"Image files","item_ids":["b1","b2"]}\
        ]}
        """

        let lines = items.map { "- \($0.id): \($0.name)" }.joined(separator: "\n")
        return """
        Group these files into subfolders. Return JSON only — no prose, \
        no markdown, no code fences. Every item_id you return must appear \
        in the input.

        Example input:
        \(examplePrompt)

        Example output:
        \(exampleAnswer)

        Now do the same for these files.

        Folder: \(folderName)
        Files:
        \(lines)

        JSON:
        """
    }

    // MARK: - Lenient JSON extraction

    /// Extract a `{"plans":[...]}` JSON document from raw model output.
    /// Returns nil if nothing recognizable is present. Tolerant of:
    ///   - Markdown code fences (```json ... ``` or ``` ... ```)
    ///   - Leading / trailing prose
    ///   - Top-level `[...]` arrays (wrapped back into `{"plans":[...]}`)
    static func extractJSON(from raw: String) -> String? {
        let cleaned = stripCodeFences(raw)

        // Decide top-level shape by which structural char appears first
        // in the response. Otherwise the `{...}` extractor would happily
        // grab the first inner object of a top-level array and we'd
        // miss the array semantics the model meant.
        let firstObject = cleaned.firstIndex(of: "{")
        let firstArray = cleaned.firstIndex(of: "[")
        if let arrIdx = firstArray, firstObject == nil || arrIdx < (firstObject ?? cleaned.endIndex) {
            if let arr = firstBalancedSubstring(in: cleaned, open: "[", close: "]") {
                return "{\"plans\":\(arr)}"
            }
        }
        if let obj = firstBalancedSubstring(in: cleaned, open: "{", close: "}") {
            return obj
        }
        return nil
    }

    private static func stripCodeFences(_ raw: String) -> String {
        var text = raw
        // Remove ```lang and ``` markers anywhere in the response. We
        // accept any language token after the backticks because small
        // models emit ```json, ```JSON, even just ```.
        let pattern = #"```[a-zA-Z]*"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        return text
    }

    private static func firstBalancedSubstring(
        in text: String,
        open: Character,
        close: Character
    ) -> String? {
        guard let start = text.firstIndex(of: open) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == open {
                    depth += 1
                } else if character == close {
                    depth -= 1
                    if depth == 0 {
                        let end = text.index(after: index)
                        return String(text[start ..< end])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

public enum MLXOrganizerError: Error, LocalizedError, Equatable {
    case modelNotLoaded
    case unparseableResponse(underlying: String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Your local MLX model isn't loaded yet. Open AI Models to download it first."
        case .unparseableResponse:
            return "Llama 3.2 1B didn't return valid JSON. Small local models drift on structured output; "
                + "try Cloud or Claude Code for this folder, or run on-device rules."
        }
    }
}
