import Foundation

// MARK: - Thermal State

/// Thermal state mapped from ProcessInfo.ThermalState for Sendable/Codable use.
public enum ThermalLevel: String, Codable, Sendable, Comparable {
    case nominal
    case fair
    case serious
    case critical

    public init(from thermalState: ProcessInfo.ThermalState) {
        switch thermalState {
        case .nominal:  self = .nominal
        case .fair:     self = .fair
        case .serious:  self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }

    /// Score from 0 (critical) to 100 (nominal).
    public var score: Int {
        switch self {
        case .nominal:  return 100
        case .fair:     return 70
        case .serious:  return 35
        case .critical: return 0
        }
    }

    private var ordinal: Int {
        switch self {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.ordinal < rhs.ordinal
    }
}

// MARK: - System Metrics

/// Snapshot of system resource usage: CPU, memory, disk, and thermal state.
///
/// All percentage fields are 0.0–1.0 fractions. The `healthScore` is a
/// weighted composite (0–100) suitable for display in `HealthGaugeView`.
public struct SystemMetrics: Sendable, Equatable {
    /// CPU usage as a fraction (0.0 = idle, 1.0 = fully loaded).
    public let cpuUsage: Double

    /// Memory pressure as a fraction (0.0 = free, 1.0 = fully used).
    public let memoryPressure: Double

    /// Total physical memory in bytes.
    public let memoryTotal: UInt64

    /// Used physical memory in bytes.
    public let memoryUsed: UInt64

    /// Disk usage as a fraction (0.0 = empty, 1.0 = full).
    public let diskUsage: Double

    /// Total disk capacity in bytes.
    public let diskTotal: UInt64

    /// Used disk space in bytes.
    public let diskUsed: UInt64

    /// Free disk space in bytes.
    public let diskFree: UInt64

    /// Current thermal state.
    public let thermalLevel: ThermalLevel

    /// When this snapshot was taken.
    public let timestamp: Date

    public init(
        cpuUsage: Double,
        memoryPressure: Double,
        memoryTotal: UInt64,
        memoryUsed: UInt64,
        diskUsage: Double,
        diskTotal: UInt64,
        diskUsed: UInt64,
        diskFree: UInt64,
        thermalLevel: ThermalLevel,
        timestamp: Date = Date()
    ) {
        self.cpuUsage = Self.sanitizedFraction(cpuUsage)
        self.memoryPressure = Self.sanitizedFraction(memoryPressure)
        self.memoryTotal = memoryTotal
        self.memoryUsed = memoryUsed
        self.diskUsage = Self.sanitizedFraction(diskUsage)
        self.diskTotal = diskTotal
        self.diskUsed = diskUsed
        self.diskFree = diskFree
        self.thermalLevel = thermalLevel
        self.timestamp = timestamp
    }

    /// Clamps a fraction to `[0, 1]`, treating non-finite inputs (`NaN`,
    /// `±infinity`) as `0`. Guards against downstream traps in `healthScore`
    /// (which calls `Int(_.rounded())`) when a misbehaving metrics source
    /// emits a division-by-zero or similar artefact.
    private static func sanitizedFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    // MARK: - Health Score

    /// Weights for the composite health score.
    ///
    /// CPU and thermal are weighted lower because transient spikes
    /// are normal. Memory and disk are weighted higher because sustained
    /// pressure directly impacts the user's ability to work.
    public enum Weight {
        public static let cpu: Double = 0.25
        public static let memory: Double = 0.30
        public static let disk: Double = 0.30
        public static let thermal: Double = 0.15
    }

    /// Composite health score (0–100).
    ///
    /// Higher is better. Each resource contributes inversely to its usage:
    /// - CPU:     `(1 - usage) × 100`
    /// - Memory:  `(1 - pressure) × 100`
    /// - Disk:    `(1 - usage) × 100`
    /// - Thermal: mapped from `ThermalLevel.score`
    public var healthScore: Int {
        let cpuScore = (1.0 - cpuUsage) * 100.0
        let memScore = (1.0 - memoryPressure) * 100.0
        let diskScore = (1.0 - diskUsage) * 100.0
        let thermalScore = Double(thermalLevel.score)

        let weighted =
            cpuScore * Weight.cpu +
            memScore * Weight.memory +
            diskScore * Weight.disk +
            thermalScore * Weight.thermal

        return min(max(Int(weighted.rounded()), 0), 100)
    }
}
