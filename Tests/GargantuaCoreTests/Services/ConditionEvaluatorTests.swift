import Foundation
import Testing
@testable import GargantuaCore

@Suite("ConditionEvaluator")
struct ConditionEvaluatorTests {
    let evaluator = ConditionEvaluator()
    let now = Date()

    // MARK: - Age Conditions

    @Test("age > 30d returns true for 31-day-old file")
    func ageGreaterThan30Days() {
        let lastAccessed = now.addingTimeInterval(-31 * 86400)
        #expect(evaluator.evaluate(condition: "age > 30d", lastAccessed: lastAccessed, now: now))
    }

    @Test("age > 30d returns false for 29-day-old file")
    func ageNotGreaterThan30Days() {
        let lastAccessed = now.addingTimeInterval(-29 * 86400)
        #expect(!evaluator.evaluate(condition: "age > 30d", lastAccessed: lastAccessed, now: now))
    }

    @Test("age > 7d returns true for 8-day-old file")
    func ageGreaterThan7Days() {
        let lastAccessed = now.addingTimeInterval(-8 * 86400)
        #expect(evaluator.evaluate(condition: "age > 7d", lastAccessed: lastAccessed, now: now))
    }

    @Test("age > 90d returns true for very old file")
    func ageGreaterThan90Days() {
        let lastAccessed = now.addingTimeInterval(-100 * 86400)
        #expect(evaluator.evaluate(condition: "age > 90d", lastAccessed: lastAccessed, now: now))
    }

    @Test("age >= 30d returns true for exactly 30-day-old file")
    func ageGreaterThanOrEqual() {
        let lastAccessed = now.addingTimeInterval(-30 * 86400)
        #expect(evaluator.evaluate(condition: "age >= 30d", lastAccessed: lastAccessed, now: now))
    }

    @Test("age < 7d returns true for 3-day-old file")
    func ageLessThan() {
        let lastAccessed = now.addingTimeInterval(-3 * 86400)
        #expect(evaluator.evaluate(condition: "age < 7d", lastAccessed: lastAccessed, now: now))
    }

    // MARK: - Hour/Minute Units

    @Test("age > 24h equivalent to age > 1d")
    func hourUnit() {
        let lastAccessed = now.addingTimeInterval(-25 * 3600)
        #expect(evaluator.evaluate(condition: "age > 24h", lastAccessed: lastAccessed, now: now))
    }

    @Test("age > 60m for minute-granularity")
    func minuteUnit() {
        let lastAccessed = now.addingTimeInterval(-61 * 60)
        #expect(evaluator.evaluate(condition: "age > 60m", lastAccessed: lastAccessed, now: now))
    }

    // MARK: - Edge Cases

    @Test("returns false when lastAccessed is nil")
    func nilLastAccessed() {
        #expect(!evaluator.evaluate(condition: "age > 30d", lastAccessed: nil, now: now))
    }

    @Test("returns false for unrecognized condition")
    func unrecognizedCondition() {
        let lastAccessed = now.addingTimeInterval(-100 * 86400)
        #expect(!evaluator.evaluate(condition: "size > 1gb", lastAccessed: lastAccessed, now: now))
    }

    @Test("handles whitespace in condition")
    func whitespaceHandling() {
        let lastAccessed = now.addingTimeInterval(-31 * 86400)
        #expect(evaluator.evaluate(condition: "  age > 30d  ", lastAccessed: lastAccessed, now: now))
    }

    @Test("age > 0d returns true for any file with lastAccessed in the past")
    func zeroThreshold() {
        let lastAccessed = now.addingTimeInterval(-1)
        #expect(evaluator.evaluate(condition: "age > 0d", lastAccessed: lastAccessed, now: now))
    }
}
