import Foundation

public extension MLXInferenceEngine {
    nonisolated static let defaultInstructions = """
    You are a helpful assistant that explains macOS cleanup items to end users. \
    Given a scanned item's metadata, explain in plain English what it is, whether \
    it is safe to delete, and any caveats. Be concise — 2 to 4 short sentences. \
    Do not include code fences, bullet lists, or markdown headers.
    """

    nonisolated static let cleanupNarrativeInstructions = """
    You are a helpful assistant that summarizes a completed macOS cleanup \
    in 1 to 2 short sentences. Describe what was cleaned and any notable \
    groupings. Plain English only — no bullet lists, no code fences, no \
    markdown headers. Do not invent items, paths, or numbers that are \
    not in the provided summary.
    """

    nonisolated static let scanFilterInstructions = """
    You translate one user query into a strict JSON object for filtering \
    macOS cleanup scan results. Output JSON only. Allowed keys are: \
    bundle_ids (array of strings), path_globs (array of glob strings), \
    categories (array of strings), min_size (integer bytes), max_size \
    (integer bytes), safety (array containing safe, review, or protected). \
    Do not emit any other keys.
    """
}

extension MLXInferenceEngine {
    /// Builds the user-turn content for `generate`. Pulled out so tests can
    /// pin the shape without spinning up a model.
    static func buildPrompt(for result: ScanResult, rule: ScanRule) -> String {
        if result.category == "process_triage" {
            return buildProcessTriagePrompt(for: result, rule: rule)
        }
        if result.category == "background_item_triage" {
            return buildBackgroundItemTriagePrompt(for: result, rule: rule)
        }

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

    static func buildProcessTriagePrompt(for result: ScanResult, rule: ScanRule) -> String {
        var lines: [String] = []
        lines.append("Running process: \(result.name)")
        lines.append("Executable path or command: \(result.path)")
        lines.append("Source app/vendor: \(result.source.name)")
        lines.append("Safety classification from Gargantua: \(result.safety.rawValue) (\(result.confidence)% confidence)")
        lines.append("Triage signals: \(triageSignals(from: result).joined(separator: ", "))")
        lines.append("Canonical context: \(rule.explanation)")
        lines.append("")
        lines.append(
            "Decide whether this process deserves user attention. "
            + "Recommend one next step: leave running, investigate, or consider stopping. "
            + "Do not claim it is malware unless the metadata proves it; "
            + "use suspicious or worth reviewing when evidence is limited. "
            + "Mention that stopping a process can disrupt the app that owns it."
        )
        return lines.joined(separator: "\n")
    }

    static func buildBackgroundItemTriagePrompt(for result: ScanResult, rule: ScanRule) -> String {
        var lines: [String] = []
        lines.append("Background item: \(result.name)")
        lines.append("Plist or executable path: \(result.path)")
        lines.append("Source app/vendor: \(result.source.name)")
        lines.append("Safety classification from Gargantua: \(result.safety.rawValue) (\(result.confidence)% confidence)")
        lines.append("Triage signals: \(triageSignals(from: result).joined(separator: ", "))")
        lines.append("Canonical context: \(rule.explanation)")
        lines.append("")
        lines.append(
            "Decide whether this background item deserves user attention. "
            + "Recommend one next step: leave enabled, investigate, disable first, "
            + "or remove only after disabling. "
            + "Do not claim it is malware unless the metadata proves it; "
            + "use suspicious or worth reviewing when evidence is limited."
        )
        return lines.joined(separator: "\n")
    }

    private static func triageSignals(from result: ScanResult) -> [String] {
        let signals = result.tags.compactMap { tag -> String? in
            guard tag.hasPrefix("triage_signal:") else { return nil }
            return tag.replacingOccurrences(of: "triage_signal:", with: "")
                .replacingOccurrences(of: "_", with: " ")
        }
        return signals.isEmpty ? ["review candidate"] : signals
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

    static func resolveModelDirectory(_ modelPath: String) throws -> URL {
        try MLXLifecycleController.resolveModelDirectory(modelPath)
    }

    static func validateModelDirectory(_ directory: URL) throws {
        try MLXLifecycleController.validateModelDirectory(directory)
    }
}
