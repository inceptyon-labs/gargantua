import Foundation

public struct CloudAIInputItem: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    public let size: Int64
    public let safety: SafetyLevel
    public let confidence: Int
    public let explanation: String
    public let sourceName: String
    public let bundleID: String?
    public let lastAccessed: Date?
    public let category: String
    public let tags: [String]
    public let regenerates: Bool
    public let regenerateCommand: String?
    public let contentPreview: String?

    public init(
        id: String,
        name: String,
        path: String,
        size: Int64,
        safety: SafetyLevel,
        confidence: Int,
        explanation: String,
        sourceName: String,
        bundleID: String?,
        lastAccessed: Date?,
        category: String,
        tags: [String],
        regenerates: Bool,
        regenerateCommand: String?,
        contentPreview: String?
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.safety = safety
        self.confidence = confidence
        self.explanation = explanation
        self.sourceName = sourceName
        self.bundleID = bundleID
        self.lastAccessed = lastAccessed
        self.category = category
        self.tags = tags
        self.regenerates = regenerates
        self.regenerateCommand = regenerateCommand
        self.contentPreview = contentPreview
    }
}

public enum CloudAIRedactor {
    public typealias ContentProvider = @Sendable (ScanResult) throws -> String?

    public static let maxContentPreviewCharacters = 4_000

    public static func items(
        from results: [ScanResult],
        allowsFileContents: Bool,
        contentProvider: ContentProvider? = nil
    ) throws -> [CloudAIInputItem] {
        try results.map { result in
            let preview: String?
            if allowsFileContents, let contentProvider {
                preview = try contentProvider(result).map(sanitizeContent)
            } else {
                preview = nil
            }

            return CloudAIInputItem(
                id: result.id,
                name: sanitizeContent(result.name),
                // Paths and bundle IDs leave the machine too, so they get the
                // same secret scrub as free-text fields. A token embedded in a
                // path COMPONENT (e.g. `~/creds/ghp_…/config`), not just the
                // leaf name, must not survive to the wire.
                path: sanitizeContent(result.path),
                size: result.size,
                safety: result.safety,
                confidence: result.confidence,
                explanation: sanitizeContent(result.explanation),
                sourceName: sanitizeContent(result.source.name),
                bundleID: result.source.bundleID.map(sanitizeContent),
                lastAccessed: result.lastAccessed,
                category: result.category,
                tags: result.tags.map(sanitizeContent),
                regenerates: result.regenerates,
                regenerateCommand: result.regenerateCommand.map(sanitizeContent),
                contentPreview: preview
            )
        }
    }

    public static func sanitizeContent(_ value: String) -> String {
        let redacted = redactPersonalDetails(redactSensitivePatterns(value))
        let scalars = redacted.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar), scalar != "\n", scalar != "\t" {
                return " "
            }
            return Character(scalar)
        }
        let collapsed = String(scalars)
            .replacingOccurrences(of: #"[ \t\r\n]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard collapsed.count > maxContentPreviewCharacters else {
            return collapsed
        }
        let end = collapsed.index(collapsed.startIndex, offsetBy: maxContentPreviewCharacters)
        return String(collapsed[..<end])
    }

    /// The macOS account name doesn't need to leave the machine: rewrite the
    /// home folder to `~`, and mask email addresses.
    static func redactPersonalDetails(_ value: String, home: String = NSHomeDirectory()) -> String {
        var output = value
        if home.count > 1 {
            output = output.replacingOccurrences(of: home, with: "~")
        }
        return output.replacingOccurrences(
            of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            with: "[REDACTED_EMAIL]",
            options: .regularExpression
        )
    }

    private static func redactSensitivePatterns(_ value: String) -> String {
        let rules = [
            (#"(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"#, "[REDACTED_PRIVATE_KEY]"),
            (#"(?i)\b(authorization:\s*bearer)\s+[A-Za-z0-9._~+/=-]{16,}"#, "$1 [REDACTED]"),
            (#"(?i)\b(api[_-]?key|access[_-]?token|auth[_-]?token|secret|password)\s*[:=]\s*["']?[^"',\s;]+"#, "$1=[REDACTED]"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "[REDACTED_AWS_ACCESS_KEY]"),
            (#"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"#, "[REDACTED_GITHUB_TOKEN]"),
            (#"\bglpat-[A-Za-z0-9_-]{20,}\b"#, "[REDACTED_GITLAB_TOKEN]"),
            (#"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#, "[REDACTED_SLACK_TOKEN]"),
            (#"\b(?:sk|rk)_(?:live|test)_[0-9A-Za-z]{16,}\b"#, "[REDACTED_STRIPE_KEY]"),
            (#"\bAIza[0-9A-Za-z_-]{35}\b"#, "[REDACTED_GOOGLE_API_KEY]"),
            (#"\bya29\.[0-9A-Za-z_-]{20,}\b"#, "[REDACTED_GOOGLE_OAUTH_TOKEN]"),
            (#"\bsk-[A-Za-z0-9_-]{20,}\b"#, "[REDACTED_API_KEY]"),
        ]

        return rules.reduce(value) { output, rule in
            output.replacingOccurrences(
                of: rule.0,
                with: rule.1,
                options: .regularExpression
            )
        }
    }
}

public enum CloudAIPromptBuilder {
    public static let systemPrompt = """
    You are Gargantua's cloud analysis assistant. You provide advisory analysis only.
    You must never override YAML safety classifications, never mark protected items for cleanup,
    and never imply an action has been performed. Prefer concise JSON responses that match
    the requested schema.
    """

    /// Prose (not JSON) prompt for a deeper, single-item explanation. Used by
    /// both the Cloud and Claude Code "Explain deeper" providers so the two
    /// paths produce comparable output.
    public static func explanationPrompt(item: CloudAIInputItem) throws -> String {
        let payload = try encodedJSON(item)
        return """
        Explain this item found by a macOS cleanup scan, for a developer deciding whether to delete it.
        Cover, in 2–4 short paragraphs of plain prose (no JSON, no headings):
        what it is and what created it, why it's on the machine, whether it's safe to remove,
        and what removing it would affect or cost to regenerate.
        This is advisory only — do not contradict or override the item's safety classification,
        and never imply the item has already been deleted.
        Inputs are path and metadata only unless a content_preview field is present.
        Item:
        \(payload)
        """
    }

    public static func deepAnalysisPrompt(items: [CloudAIInputItem]) throws -> String {
        let payload = try encodedJSON(items)
        return """
        Analyze these scan results for cross-file cleanup patterns.
        Return JSON: {"summary":"...","recommendations":["..."]}.
        Inputs are path and metadata only unless a content_preview field is present.
        Items:
        \(payload)
        """
    }

    public static func targetCleanupPrompt(items: [CloudAIInputItem], targetBytes: Int64) throws -> String {
        let payload = try encodedJSON(items)
        return """
        Propose a cleanup set that frees at least \(targetBytes) bytes while respecting YAML safety.
        Use only item ids whose safety is safe or review. Exclude protected items.
        Return JSON: {"item_ids":["id"],"rationale":"..."}.
        Items:
        \(payload)
        """
    }

    public static func duplicateResolutionPrompt(groups: [CloudAIDuplicateGroupInput]) throws -> String {
        let payload = try encodedJSON(groups)
        return """
        Recommend which duplicate file to keep in each group.
        Return JSON: {"suggestions":[{"group_id":"...","keep_id":"...","delete_ids":["..."],"rationale":"..."}]}.
        Never include protected files in delete_ids.
        Groups:
        \(payload)
        """
    }

    public static func scanRuleSuggestionPrompt(items: [CloudAIInputItem]) throws -> String {
        let payload = try encodedJSON(items)
        return """
        Suggest YAML cleanup rules for recurring patterns in these scan results.
        Return JSON: {"yaml":"rules:\\n  - id: ...","rationale":"..."}.
        The caller will write your output to a proposed-rules file only, never to live bundled rules.
        Items:
        \(payload)
        """
    }

    private static func encodedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public struct CloudAIDuplicateGroupInput: Codable, Sendable, Equatable {
    public let id: String
    public let shortHash: String
    public let reclaimableCeilingBytes: Int64
    public let files: [CloudAIInputItem]

    public init(group: DuplicateGroup, allowsFileContents: Bool = false) throws {
        self.id = group.id
        self.shortHash = group.shortHash
        self.reclaimableCeilingBytes = group.reclaimableCeilingBytes
        self.files = try CloudAIRedactor.items(
            from: group.files,
            allowsFileContents: allowsFileContents
        )
    }
}
