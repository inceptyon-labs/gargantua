import Testing
import SwiftUI
@testable import GargantuaCore

// MARK: - Health Score Range

@Suite("HealthScoreRange")
struct HealthScoreRangeTests {
    @Test("Score 80-100 is healthy")
    func healthyRange() {
        for score in [80, 90, 100] {
            #expect(HealthScoreRange(score: score) == .healthy)
        }
    }

    @Test("Score 50-79 is moderate")
    func moderateRange() {
        for score in [50, 65, 79] {
            #expect(HealthScoreRange(score: score) == .moderate)
        }
    }

    @Test("Score 0-49 is poor")
    func poorRange() {
        for score in [0, 25, 49] {
            #expect(HealthScoreRange(score: score) == .poor)
        }
    }

    @Test("Boundary: 49 is poor, 50 is moderate, 79 is moderate, 80 is healthy")
    func boundaries() {
        #expect(HealthScoreRange(score: 49) == .poor)
        #expect(HealthScoreRange(score: 50) == .moderate)
        #expect(HealthScoreRange(score: 79) == .moderate)
        #expect(HealthScoreRange(score: 80) == .healthy)
    }

    @Test("Out-of-range scores are clamped: -5 is poor, 101 is healthy")
    func outOfRangeClamped() {
        #expect(HealthScoreRange(score: -5) == .poor)
        #expect(HealthScoreRange(score: 101) == .healthy)
    }

    @Test("Healthy maps to safe color")
    func healthyColor() {
        #expect(HealthScoreRange.healthy.color == GargantuaColors.safe)
    }

    @Test("Moderate maps to review color")
    func moderateColor() {
        #expect(HealthScoreRange.moderate.color == GargantuaColors.review)
    }

    @Test("Poor maps to protected color")
    func poorColor() {
        #expect(HealthScoreRange.poor.color == GargantuaColors.protected_)
    }
}

// MARK: - Health Gauge View

@Suite("HealthGaugeView")
struct HealthGaugeViewTests {
    @Test("diskUsage clamped to 0 minimum")
    func clampDiskMin() {
        let gauge = HealthGaugeView(diskUsage: -0.5)
        #expect(gauge.diskUsage == 0)
    }

    @Test("diskUsage clamped to 1 maximum")
    func clampDiskMax() {
        let gauge = HealthGaugeView(diskUsage: 1.5)
        #expect(gauge.diskUsage == 1)
    }

    @Test("reclaimableFraction clamped to 0 minimum")
    func clampReclaimMin() {
        let gauge = HealthGaugeView(diskUsage: 0.5, reclaimableFraction: -0.1)
        #expect(gauge.reclaimableFraction == 0)
    }

    @Test("reclaimableFraction clamped to 1 maximum")
    func clampReclaimMax() {
        let gauge = HealthGaugeView(diskUsage: 0.5, reclaimableFraction: 2.0)
        #expect(gauge.reclaimableFraction == 1)
    }

    @Test("Values within range are not clamped")
    func noClamp() {
        let gauge = HealthGaugeView(diskUsage: 0.74, reclaimableFraction: 0.08)
        #expect(gauge.diskUsage == 0.74)
        #expect(gauge.reclaimableFraction == 0.08)
    }

    @Test("Default size is 120")
    func defaultSize() {
        let gauge = HealthGaugeView(diskUsage: 0.5)
        #expect(gauge.size == 120)
    }

    @Test("Custom size is respected")
    func customSize() {
        let gauge = HealthGaugeView(diskUsage: 0.5, size: 200, lineWidth: 12)
        #expect(gauge.size == 200)
        #expect(gauge.lineWidth == 12)
    }
}
