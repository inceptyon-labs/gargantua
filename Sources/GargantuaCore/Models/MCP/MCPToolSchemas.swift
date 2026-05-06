import Foundation

// MARK: - scan

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

// MARK: - analyze

/// Empty input payload for the MCP `analyze` tool.
public struct MCPAnalyzeInput: Codable, Sendable, Equatable {
    /// Creates an empty analyze input.
    public init() {}
}

/// Human-readable disk usage values returned by `analyze`.
public struct MCPDiskUsage: Codable, Sendable, Equatable {
    /// Total capacity string for the analyzed disk.
    public let total: String
    /// Used capacity string for the analyzed disk.
    public let used: String
    /// Free capacity string for the analyzed disk.
    public let free: String

    /// Creates a disk usage block for MCP output.
    public init(total: String, used: String, free: String) {
        self.total = total
        self.used = used
        self.free = free
    }
}

/// Large filesystem consumer surfaced by the MCP analyzer.
public struct MCPTopConsumer: Codable, Sendable, Equatable {
    /// Display name for the consumer.
    public let name: String
    /// Filesystem path for the consumer.
    public let path: String
    /// Human-readable size string for the consumer.
    public let size: String

    /// Creates a top-consumer row.
    public init(name: String, path: String, size: String) {
        self.name = name
        self.path = path
        self.size = size
    }
}

/// Complete MCP `analyze` response payload.
public struct MCPAnalyzeOutput: Codable, Sendable, Equatable {
    /// Overall file-health score returned to MCP clients.
    public let healthScore: Int
    /// Disk usage summary for the current system.
    public let disk: MCPDiskUsage
    /// Largest consumers found by the analyzer.
    public let topConsumers: [MCPTopConsumer]
    /// User-facing recommendations derived from the analysis.
    public let recommendations: [String]

    /// Creates an analyze output payload.
    public init(
        healthScore: Int,
        disk: MCPDiskUsage,
        topConsumers: [MCPTopConsumer],
        recommendations: [String]
    ) {
        self.healthScore = healthScore
        self.disk = disk
        self.topConsumers = topConsumers
        self.recommendations = recommendations
    }

    enum CodingKeys: String, CodingKey {
        case disk, recommendations
        case healthScore = "health_score"
        case topConsumers = "top_consumers"
    }
}

// MARK: - explain

/// Input for `explain`: exactly one of `path` or `itemId` must be supplied.
public struct MCPExplainInput: Codable, Sendable, Equatable {
    /// Filesystem path to explain when addressing an item by path.
    public let path: String?
    /// Scan item identifier to explain when addressing a previous result.
    public let itemId: String?

    /// Creates an explain input before validation.
    public init(path: String? = nil, itemId: String? = nil) {
        self.path = path
        self.itemId = itemId
    }

    enum CodingKeys: String, CodingKey {
        case path
        case itemId = "item_id"
    }

    /// Decodes and validates that exactly one lookup key is present.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let path = try c.decodeIfPresent(String.self, forKey: .path)
        let itemId = try c.decodeIfPresent(String.self, forKey: .itemId)
        switch (path, itemId) {
        case (nil, nil):
            throw DecodingError.dataCorruptedError(
                forKey: .path,
                in: c,
                debugDescription: "explain requires exactly one of path or item_id."
            )
        case (.some, .some):
            throw DecodingError.dataCorruptedError(
                forKey: .path,
                in: c,
                debugDescription: "explain accepts path or item_id, not both."
            )
        default:
            self.path = path
            self.itemId = itemId
        }
    }
}

/// Receipt provenance attached to an explained item.
///
/// Mirrors the relevant fields of `PackageReceipt` so an MCP client can
/// render audit-grade explanations like "we found this because
/// com.docker.docker (v4.30.0) installed it on 2025-12-04". Multiple
/// packages can claim a single path, so explain output carries an array.
public struct MCPReceiptProvenance: Codable, Sendable, Equatable {
    /// Reverse-DNS package identifier (e.g., `com.docker.docker`).
    public let pkgID: String
    /// Package version when readable from the receipt.
    public let pkgVersion: String?
    /// Install timestamp when readable from the receipt.
    public let installDate: Date?

    /// Creates a receipt provenance entry.
    public init(
        pkgID: String,
        pkgVersion: String? = nil,
        installDate: Date? = nil
    ) {
        self.pkgID = pkgID
        self.pkgVersion = pkgVersion
        self.installDate = installDate
    }

    enum CodingKeys: String, CodingKey {
        case pkgID = "pkg_id"
        case pkgVersion = "pkg_version"
        case installDate = "install_date"
    }
}

/// Explanation details returned for one scan item or path.
public struct MCPExplainOutput: Codable, Sendable, Equatable {
    /// Display name for the explained item.
    public let name: String
    /// Safety classification string for the item.
    public let safety: String
    /// Confidence score for the explanation.
    public let confidence: Int
    /// Human-readable explanation text.
    public let explanation: String
    /// Optional human-readable size string.
    public let size: String?
    /// Optional last access timestamp.
    public let lastAccessed: Date?
    /// Receipts that claim the explained path, when receipt evidence is
    /// available. Omitted (encoded as `null`) when the path is not owned
    /// by any package receipt.
    public let receipts: [MCPReceiptProvenance]?

    /// Creates an explanation output payload.
    public init(
        name: String,
        safety: String,
        confidence: Int,
        explanation: String,
        size: String? = nil,
        lastAccessed: Date? = nil,
        receipts: [MCPReceiptProvenance]? = nil
    ) {
        self.name = name
        self.safety = safety
        self.confidence = confidence
        self.explanation = explanation
        self.size = size
        self.lastAccessed = lastAccessed
        self.receipts = receipts
    }

    enum CodingKeys: String, CodingKey {
        case name, safety, confidence, explanation, size, receipts
        case lastAccessed = "last_accessed"
    }
}

// MARK: - list_profiles

/// Empty input payload for the MCP `list_profiles` tool.
public struct MCPListProfilesInput: Codable, Sendable, Equatable {
    /// Creates an empty list-profiles input.
    public init() {}
}

/// Short profile description returned by `list_profiles`.
public struct MCPProfileSummary: Codable, Sendable, Equatable {
    /// Profile identifier or display name.
    public let name: String
    /// Categories enabled by the profile.
    public let categories: [String]
    /// User-facing profile description.
    public let description: String

    /// Creates a profile summary row.
    public init(name: String, categories: [String], description: String) {
        self.name = name
        self.categories = categories
        self.description = description
    }
}

/// Complete MCP `list_profiles` response payload.
public struct MCPListProfilesOutput: Codable, Sendable, Equatable {
    /// Profiles available to MCP callers.
    public let profiles: [MCPProfileSummary]
    /// Active profile identifier.
    public let active: String

    /// Creates a list-profiles output payload.
    public init(profiles: [MCPProfileSummary], active: String) {
        self.profiles = profiles
        self.active = active
    }
}

// MARK: - status

/// Empty input payload for the MCP `status` tool.
public struct MCPStatusInput: Codable, Sendable, Equatable {
    /// Creates an empty status input.
    public init() {}
}

/// CPU usage fields returned by the MCP `status` tool.
public struct MCPStatusCPU: Codable, Sendable, Equatable {
    /// Current CPU usage percentage.
    public let usage: Double
    /// Number of logical cores reported by the system.
    public let cores: Int

    /// Creates a CPU status block.
    public init(usage: Double, cores: Int) {
        self.usage = usage
        self.cores = cores
    }
}

/// Memory usage fields returned by the MCP `status` tool.
public struct MCPStatusMemory: Codable, Sendable, Equatable {
    /// Human-readable used-memory string.
    public let used: String
    /// Human-readable total-memory string.
    public let total: String
    /// Used-memory percentage.
    public let percent: Double

    /// Creates a memory status block.
    public init(used: String, total: String, percent: Double) {
        self.used = used
        self.total = total
        self.percent = percent
    }
}

/// Disk usage fields returned by the MCP `status` tool.
public struct MCPStatusDisk: Codable, Sendable, Equatable {
    /// Human-readable used-disk string.
    public let used: String
    /// Human-readable total-disk string.
    public let total: String
    /// Used-disk percentage.
    public let percent: Double

    /// Creates a disk status block.
    public init(used: String, total: String, percent: Double) {
        self.used = used
        self.total = total
        self.percent = percent
    }
}

/// Complete MCP `status` response payload.
public struct MCPStatusOutput: Codable, Sendable, Equatable {
    /// Overall health score for the current system state.
    public let healthScore: Int
    /// CPU usage summary.
    public let cpu: MCPStatusCPU
    /// Memory usage summary.
    public let memory: MCPStatusMemory
    /// Disk usage summary.
    public let disk: MCPStatusDisk
    /// Human-readable process or system uptime.
    public let uptime: String

    /// Creates a status output payload.
    public init(
        healthScore: Int,
        cpu: MCPStatusCPU,
        memory: MCPStatusMemory,
        disk: MCPStatusDisk,
        uptime: String
    ) {
        self.healthScore = healthScore
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.uptime = uptime
    }

    enum CodingKeys: String, CodingKey {
        case cpu, memory, disk, uptime
        case healthScore = "health_score"
    }
}
