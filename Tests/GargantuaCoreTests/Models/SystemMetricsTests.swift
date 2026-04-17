import Testing
import Foundation
@testable import GargantuaCore

// MARK: - ThermalLevel

@Suite("ThermalLevel")
struct ThermalLevelTests {
    @Test("Score mapping: nominal=100, fair=70, serious=35, critical=0")
    func scoreMapping() {
        #expect(ThermalLevel.nominal.score == 100)
        #expect(ThermalLevel.fair.score == 70)
        #expect(ThermalLevel.serious.score == 35)
        #expect(ThermalLevel.critical.score == 0)
    }

    @Test("Comparable ordering: nominal < fair < serious < critical")
    func ordering() {
        #expect(ThermalLevel.nominal < .fair)
        #expect(ThermalLevel.fair < .serious)
        #expect(ThermalLevel.serious < .critical)
    }

    @Test("Init from ProcessInfo.ThermalState")
    func fromThermalState() {
        #expect(ThermalLevel(from: .nominal) == .nominal)
        #expect(ThermalLevel(from: .fair) == .fair)
        #expect(ThermalLevel(from: .serious) == .serious)
        #expect(ThermalLevel(from: .critical) == .critical)
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = ThermalLevel.serious
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThermalLevel.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - SystemMetrics Health Score

@Suite("SystemMetrics")
struct SystemMetricsTests {

    /// Helper to create metrics with specific values.
    private func makeMetrics(
        cpu: Double = 0,
        memory: Double = 0,
        disk: Double = 0,
        thermal: ThermalLevel = .nominal
    ) -> SystemMetrics {
        SystemMetrics(
            cpuUsage: cpu,
            memoryPressure: memory,
            memoryTotal: 16_000_000_000,
            memoryUsed: UInt64(Double(16_000_000_000) * memory),
            diskUsage: disk,
            diskTotal: 500_000_000_000,
            diskUsed: UInt64(Double(500_000_000_000) * disk),
            diskFree: UInt64(Double(500_000_000_000) * (1 - disk)),
            thermalLevel: thermal
        )
    }

    @Test("Perfect system scores 100")
    func perfectScore() {
        let m = makeMetrics(cpu: 0, memory: 0, disk: 0, thermal: .nominal)
        #expect(m.healthScore == 100)
    }

    @Test("Fully loaded system scores 0")
    func worstScore() {
        let m = makeMetrics(cpu: 1.0, memory: 1.0, disk: 1.0, thermal: .critical)
        #expect(m.healthScore == 0)
    }

    @Test("50% across the board with nominal thermal")
    func halfLoaded() {
        let m = makeMetrics(cpu: 0.5, memory: 0.5, disk: 0.5, thermal: .nominal)
        // CPU: 50 * 0.25 = 12.5
        // Mem: 50 * 0.30 = 15.0
        // Disk: 50 * 0.30 = 15.0
        // Thermal: 100 * 0.15 = 15.0
        // Total: 57.5 → 58
        #expect(m.healthScore == 58)
    }

    @Test("Thermal critical with everything else perfect")
    func thermalOnly() {
        let m = makeMetrics(cpu: 0, memory: 0, disk: 0, thermal: .critical)
        // CPU: 100 * 0.25 = 25
        // Mem: 100 * 0.30 = 30
        // Disk: 100 * 0.30 = 30
        // Thermal: 0 * 0.15 = 0
        // Total: 85
        #expect(m.healthScore == 85)
    }

    @Test("Disk full with everything else perfect")
    func diskFullOnly() {
        let m = makeMetrics(cpu: 0, memory: 0, disk: 1.0, thermal: .nominal)
        // CPU: 100 * 0.25 = 25
        // Mem: 100 * 0.30 = 30
        // Disk: 0 * 0.30 = 0
        // Thermal: 100 * 0.15 = 15
        // Total: 70
        #expect(m.healthScore == 70)
    }

    @Test("Weights sum to 1.0")
    func weightsSumToOne() {
        let sum = SystemMetrics.Weight.cpu +
                  SystemMetrics.Weight.memory +
                  SystemMetrics.Weight.disk +
                  SystemMetrics.Weight.thermal
        #expect(sum == 1.0)
    }

    @Test("Input values are clamped to 0-1")
    func clamping() {
        let m = SystemMetrics(
            cpuUsage: 1.5,
            memoryPressure: -0.5,
            memoryTotal: 16_000_000_000,
            memoryUsed: 0,
            diskUsage: 2.0,
            diskTotal: 500_000_000_000,
            diskUsed: 500_000_000_000,
            diskFree: 0,
            thermalLevel: .nominal
        )
        #expect(m.cpuUsage == 1.0)
        #expect(m.memoryPressure == 0.0)
        #expect(m.diskUsage == 1.0)
    }

    @Test("Health score integrates with HealthScoreRange")
    func healthScoreRange() {
        let healthy = makeMetrics(cpu: 0.1, memory: 0.1, disk: 0.1, thermal: .nominal)
        #expect(HealthScoreRange(score: healthy.healthScore) == .healthy)

        let poor = makeMetrics(cpu: 0.9, memory: 0.9, disk: 0.9, thermal: .critical)
        #expect(HealthScoreRange(score: poor.healthScore) == .poor)
    }
}

