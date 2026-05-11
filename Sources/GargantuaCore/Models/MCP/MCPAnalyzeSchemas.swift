import Foundation

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
