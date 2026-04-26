import Foundation
import Testing
@testable import GargantuaCore

@Suite("SystemMetricCollector")
struct SystemMetricCollectorTests {

    @Test("collect returns metrics with cpu in 0...1")
    func cpuUsageInRange() async {
        let metrics = await SystemMetricCollector().collect()
        #expect((0.0 ... 1.0).contains(metrics.cpuUsage))
    }

    @Test("collect returns metrics with memory pressure in 0...1")
    func memoryPressureInRange() async {
        let metrics = await SystemMetricCollector().collect()
        #expect((0.0 ... 1.0).contains(metrics.memoryPressure))
    }

    @Test("collect returns positive total memory on macOS")
    func totalMemoryPositive() async {
        let metrics = await SystemMetricCollector().collect()
        #expect(metrics.memoryTotal > 0)
    }

    @Test("collect returns used memory less than or equal to total")
    func usedMemoryWithinTotal() async {
        let metrics = await SystemMetricCollector().collect()
        #expect(metrics.memoryUsed <= metrics.memoryTotal)
    }

    @Test("collect returns disk usage in 0...1")
    func diskUsageInRange() async {
        let metrics = await SystemMetricCollector().collect()
        #expect((0.0 ... 1.0).contains(metrics.diskUsage))
    }

    @Test("collect returns positive total disk on macOS")
    func totalDiskPositive() async {
        let metrics = await SystemMetricCollector().collect()
        #expect(metrics.diskTotal > 0)
    }

    @Test("collect disk: used + free <= total (at most total due to reserved blocks)")
    func diskUsedPlusFreeWithinTotal() async {
        let metrics = await SystemMetricCollector().collect()
        // used + free may be less than total because of reserved filesystem blocks.
        #expect(metrics.diskUsed + metrics.diskFree <= metrics.diskTotal)
    }

    @Test("collect disk: used consistent with usage fraction")
    func diskUsedConsistentWithFraction() async {
        let metrics = await SystemMetricCollector().collect()
        guard metrics.diskTotal > 0 else { return }
        let expected = Double(metrics.diskUsed) / Double(metrics.diskTotal)
        #expect(abs(metrics.diskUsage - expected) < 0.001)
    }

    @Test("collect returns a valid thermal level")
    func thermalLevelIsValid() async {
        let metrics = await SystemMetricCollector().collect()
        let validLevels: [ThermalLevel] = [.nominal, .fair, .serious, .critical]
        #expect(validLevels.contains(metrics.thermalLevel))
    }

    @Test("collect is idempotent — two snapshots have consistent shapes")
    func collectIsIdempotent() async {
        let a = await SystemMetricCollector().collect()
        let b = await SystemMetricCollector().collect()
        // Disk total doesn't change between two rapid calls.
        #expect(a.diskTotal == b.diskTotal)
        #expect(a.memoryTotal == b.memoryTotal)
    }

    @Test("healthScore is in 0...100")
    func healthScoreInRange() async {
        let metrics = await SystemMetricCollector().collect()
        #expect((0 ... 100).contains(metrics.healthScore))
    }
}
