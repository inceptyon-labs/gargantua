import Foundation

// MARK: - scan

/// Input for the MCP `scan` tool.
///
/// `dryRun` is modeled as a non-optional constant `true`; decoding a payload
/// with `dry_run: false` fails, enforcing the PRD §7.4 guardrail at the type
/// boundary rather than relying on the dispatcher to remember.
public struct MCPScanInput: Codable, Sendable, Equatable {
    public let profile: String?
    public let categories: [String]?
    public let dryRun: Bool

    public init(profile: String? = nil, categories: [String]? = nil, dryRun: Bool = true) {
        self.profile = profile
        self.categories = categories
        self.dryRun = dryRun
    }

    enum CodingKeys: String, CodingKey {
        case profile, categories
        case dryRun = "dry_run"
    }

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
    public let id: String
    public let name: String
    public let path: String
    public let size: String
    public let safety: String
    public let confidence: Int
    public let explanation: String
    public let source: String
    public let lastAccessed: Date?
    public let category: String

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
    public let safeCount: Int
    public let safeSize: String
    public let reviewCount: Int
    public let reviewSize: String
    public let protectedCount: Int

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

public struct MCPScanOutput: Codable, Sendable, Equatable {
    public let totalReclaimable: String
    public let items: [MCPScanItem]
    public let summary: MCPScanSummary

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

public struct MCPAnalyzeInput: Codable, Sendable, Equatable {
    public init() {}
}

public struct MCPDiskUsage: Codable, Sendable, Equatable {
    public let total: String
    public let used: String
    public let free: String

    public init(total: String, used: String, free: String) {
        self.total = total
        self.used = used
        self.free = free
    }
}

public struct MCPTopConsumer: Codable, Sendable, Equatable {
    public let name: String
    public let path: String
    public let size: String

    public init(name: String, path: String, size: String) {
        self.name = name
        self.path = path
        self.size = size
    }
}

public struct MCPAnalyzeOutput: Codable, Sendable, Equatable {
    public let healthScore: Int
    public let disk: MCPDiskUsage
    public let topConsumers: [MCPTopConsumer]
    public let recommendations: [String]

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
    public let path: String?
    public let itemId: String?

    public init(path: String? = nil, itemId: String? = nil) {
        self.path = path
        self.itemId = itemId
    }

    enum CodingKeys: String, CodingKey {
        case path
        case itemId = "item_id"
    }

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

public struct MCPExplainOutput: Codable, Sendable, Equatable {
    public let name: String
    public let safety: String
    public let confidence: Int
    public let explanation: String
    public let size: String?
    public let lastAccessed: Date?

    public init(
        name: String,
        safety: String,
        confidence: Int,
        explanation: String,
        size: String? = nil,
        lastAccessed: Date? = nil
    ) {
        self.name = name
        self.safety = safety
        self.confidence = confidence
        self.explanation = explanation
        self.size = size
        self.lastAccessed = lastAccessed
    }

    enum CodingKeys: String, CodingKey {
        case name, safety, confidence, explanation, size
        case lastAccessed = "last_accessed"
    }
}

// MARK: - list_profiles

public struct MCPListProfilesInput: Codable, Sendable, Equatable {
    public init() {}
}

public struct MCPProfileSummary: Codable, Sendable, Equatable {
    public let name: String
    public let categories: [String]
    public let description: String

    public init(name: String, categories: [String], description: String) {
        self.name = name
        self.categories = categories
        self.description = description
    }
}

public struct MCPListProfilesOutput: Codable, Sendable, Equatable {
    public let profiles: [MCPProfileSummary]
    public let active: String

    public init(profiles: [MCPProfileSummary], active: String) {
        self.profiles = profiles
        self.active = active
    }
}

// MARK: - status

public struct MCPStatusInput: Codable, Sendable, Equatable {
    public init() {}
}

public struct MCPStatusCPU: Codable, Sendable, Equatable {
    public let usage: Double
    public let cores: Int

    public init(usage: Double, cores: Int) {
        self.usage = usage
        self.cores = cores
    }
}

public struct MCPStatusMemory: Codable, Sendable, Equatable {
    public let used: String
    public let total: String
    public let percent: Double

    public init(used: String, total: String, percent: Double) {
        self.used = used
        self.total = total
        self.percent = percent
    }
}

public struct MCPStatusDisk: Codable, Sendable, Equatable {
    public let used: String
    public let total: String
    public let percent: Double

    public init(used: String, total: String, percent: Double) {
        self.used = used
        self.total = total
        self.percent = percent
    }
}

public struct MCPStatusOutput: Codable, Sendable, Equatable {
    public let healthScore: Int
    public let cpu: MCPStatusCPU
    public let memory: MCPStatusMemory
    public let disk: MCPStatusDisk
    public let uptime: String

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
