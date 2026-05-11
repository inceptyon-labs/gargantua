import Foundation

/// Input for the MCP `scan` tool.
///
/// `dryRun` is modeled as a non-optional constant `true`; decoding a payload
/// with `dry_run: false` fails, enforcing the PRD §7.4 guardrail at the type
/// boundary rather than relying on the dispatcher to remember.
public struct MCPScanInput: Codable, Sendable, Equatable {
    /// Optional cleanup profile identifier to use for the scan.
    public let profile: String?
    /// Optional category filters requested by the caller.
    public let categories: [String]?
    /// Guardrail flag that must remain `true` for MCP scan requests.
    public let dryRun: Bool

    /// Creates a scan request, defaulting to the required dry-run mode.
    public init(profile: String? = nil, categories: [String]? = nil, dryRun: Bool = true) {
        self.profile = profile
        self.categories = categories
        self.dryRun = dryRun
    }

    enum CodingKeys: String, CodingKey {
        case profile, categories
        case dryRun = "dry_run"
    }

    /// Decodes a scan request while rejecting attempts to disable dry-run mode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.profile = try c.decodeIfPresent(String.self, forKey: .profile)
        self.categories = try c.decodeIfPresent([String].self, forKey: .categories)
        let raw = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? true
        guard raw == true else {
            throw DecodingError.dataCorruptedError(
                forKey: .dryRun,
                in: c,
                debugDescription: "MCP scan.dry_run must be true; MCP cannot bypass dry-run."
            )
        }
        self.dryRun = true
    }
}

/// A single scan-result row as surfaced over MCP.
///
/// This mirrors the subset of `ScanResult` the MCP contract promises (PRD
/// §7.3). Sizes are exposed as human-readable strings so the tool output
/// matches the PRD example payload exactly; byte counts remain available on
/// the richer in-process `ScanResult` for UI consumers.
public struct MCPScanItem: Codable, Sendable, Equatable {
    /// Stable item identifier used by later MCP tool calls.
    public let id: String
    /// Display name for the scanned item.
    public let name: String
    /// Filesystem path for the scanned item.
    public let path: String
    /// Human-readable size string exposed in tool output.
    public let size: String
    /// Safety classification string for the item.
    public let safety: String
    /// Confidence score assigned by the scanner or rule.
    public let confidence: Int
    /// User-facing explanation for why the item was found.
    public let explanation: String
    /// Source rule or scanner label that produced the item.
    public let source: String
    /// Last access timestamp when available from the scanner.
    public let lastAccessed: Date?
    /// Cleanup category associated with the item.
    public let category: String

    /// Creates a scan item row for MCP responses.
    public init(
        id: String,
        name: String,
        path: String,
        size: String,
        safety: String,
        confidence: Int,
        explanation: String,
        source: String,
        lastAccessed: Date? = nil,
        category: String
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.safety = safety
        self.confidence = confidence
        self.explanation = explanation
        self.source = source
        self.lastAccessed = lastAccessed
        self.category = category
    }

    enum CodingKeys: String, CodingKey {
        case id, name, path, size, safety, confidence, explanation, source, category
        case lastAccessed = "last_accessed"
    }
}

/// Summary block returned alongside the scan item list.
public struct MCPScanSummary: Codable, Sendable, Equatable {
    /// Number of items classified as safe to clean.
    public let safeCount: Int
    /// Human-readable total size for safe items.
    public let safeSize: String
    /// Number of items that require review before cleanup.
    public let reviewCount: Int
    /// Human-readable total size for review items.
    public let reviewSize: String
    /// Number of protected items excluded from cleanup.
    public let protectedCount: Int

    /// Creates the aggregate scan summary shown beside scan results.
    public init(
        safeCount: Int,
        safeSize: String,
        reviewCount: Int,
        reviewSize: String,
        protectedCount: Int
    ) {
        self.safeCount = safeCount
        self.safeSize = safeSize
        self.reviewCount = reviewCount
        self.reviewSize = reviewSize
        self.protectedCount = protectedCount
    }

    enum CodingKeys: String, CodingKey {
        case safeCount = "safe_count"
        case safeSize = "safe_size"
        case reviewCount = "review_count"
        case reviewSize = "review_size"
        case protectedCount = "protected_count"
    }
}

/// Complete MCP `scan` response payload.
public struct MCPScanOutput: Codable, Sendable, Equatable {
    /// Human-readable total reclaimable size across actionable items.
    public let totalReclaimable: String
    /// Individual scan rows returned to the MCP client.
    public let items: [MCPScanItem]
    /// Aggregate counts and sizes for the scan.
    public let summary: MCPScanSummary

    /// Creates a scan output payload.
    public init(totalReclaimable: String, items: [MCPScanItem], summary: MCPScanSummary) {
        self.totalReclaimable = totalReclaimable
        self.items = items
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case items, summary
        case totalReclaimable = "total_reclaimable"
    }
}
