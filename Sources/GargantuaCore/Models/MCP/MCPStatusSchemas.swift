import Foundation

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
