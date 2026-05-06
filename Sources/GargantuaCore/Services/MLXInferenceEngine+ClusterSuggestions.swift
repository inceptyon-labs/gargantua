import Foundation

private struct MLXJSONBlockScanner {
    let opening: Character
    let closing: Character
    private var depth = 0
    private var inString = false
    private var escaping = false

    init(opening: Character, closing: Character) {
        self.opening = opening
        self.closing = closing
    }

    mutating func consume(_ c: Character) -> Bool {
        if escaping {
            escaping = false
            return false
        }
        if inString {
            return consumeString(c)
        }
        return consumeStructure(c)
    }

    private mutating func consumeString(_ c: Character) -> Bool {
        if c == "\\" {
            escaping = true
        } else if c == "\"" {
            inString = false
        }
        return false
    }

    private mutating func consumeStructure(_ c: Character) -> Bool {
        if c == "\"" {
            inString = true
        } else if c == opening {
            depth += 1
        } else if c == closing {
            depth -= 1
            return depth == 0
        }
        return false
    }
}

public extension MLXInferenceEngine {
    nonisolated static let clusterSuggestionInstructions = """
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
}

extension MLXInferenceEngine {
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
        lines.append(
            "Return JSON only, with shape: " +
                "{\"suggestions\":[{\"cluster_id\":\"…\",\"label\":\"…\"," +
                "\"safety\":\"safe|review|protected\",\"rationale\":\"…\"}]}."
        )
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

    private static func extractSuggestionEntries(from response: String) -> [[String: Any]]? {
        if let json = extractFirstJSONObject(from: response),
           let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = parsed["suggestions"] as? [[String: Any]] {
            return raw
        }
        if let array = extractFirstJSONArray(from: response),
           let data = array.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return parsed
        }
        return nil
    }

    /// Same balanced-scan as `extractFirstJSONObject`, but for `[...]`. Used
    /// when the model emits the suggestions array without the object wrapper.
    static func extractFirstJSONArray(from text: String) -> String? {
        extractFirstBalancedBlock(from: text, opening: "[", closing: "]")
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
        extractFirstBalancedBlock(from: text, opening: "{", closing: "}")
    }

    private static func extractFirstBalancedBlock(
        from text: String,
        opening: Character,
        closing: Character
    ) -> String? {
        guard let start = text.firstIndex(of: opening) else { return nil }
        var scanner = MLXJSONBlockScanner(opening: opening, closing: closing)
        var i = start
        while i < text.endIndex {
            if scanner.consume(text[i]) {
                return String(text[start ... i])
            }
            i = text.index(after: i)
        }
        return nil
    }
}
