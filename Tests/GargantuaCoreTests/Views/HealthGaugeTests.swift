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
    @Test("Score clamped to 0 minimum")
    func clampMin() {
        let gauge = HealthGaugeView(score: -10)
        #expect(gauge.score == 0)
    }

    @Test("Score clamped to 100 maximum")
    func clampMax() {
        let gauge = HealthGaugeView(score: 150)
        #expect(gauge.score == 100)
    }

    @Test("Score within range is not clamped")
    func noClamp() {
        let gauge = HealthGaugeView(score: 75)
        #expect(gauge.score == 75)
    }

    @Test("Default size is 120")
    func defaultSize() {
        let gauge = HealthGaugeView(score: 50)
        #expect(gauge.size == 120)
    }

    @Test("Custom size is respected")
    func customSize() {
        let gauge = HealthGaugeView(score: 50, size: 200, lineWidth: 12)
        #expect(gauge.size == 200)
        #expect(gauge.lineWidth == 12)
    }
}
