import Foundation
import Testing
@testable import GargantuaCore

private func makeRule(
    safety: SafetyLevel = .review,
    confidence: Int = 85,
    explanation: String = "Test rule",
    overrides: [SafetyOverride] = []
) -> ScanRule {
    ScanRule(
        id: "test_rule",
        name: "Test Rule",
        paths: ["/test"],
        safety: safety,
        confidence: confidence,
        explanation: explanation,
        source: SourceAttribution(name: "Test"),
        category: "dev_artifacts",
        safetyOverrides: overrides
    )
}

private func makeResult(lastAccessed: Date? = nil) -> ScanResult {
    ScanResult(
        id: "test_001",
        name: "Test Item",
        path: "/test/item",
        size: 1024,
        safety: .review,
        confidence: 85,
        explanation: "Test",
        source: SourceAttribution(name: "Test"),
        lastAccessed: lastAccessed,
        category: "dev_artifacts"
    )
}

@Suite("SafetyClassifier base classification, batch, and nil lastAccessed")
struct SafetyClassifierTests {
    let classifier = SafetyClassifier()
    let now = Date()

    // MARK: - Base Classification (No Overrides)

    @Test("Returns base safety when no overrides match")
    func noOverrideMatch() {
        let rule = makeRule(safety: .review, confidence: 80, explanation: "Original explanation")
        let result = makeResult()

        let classified = classifier.classify(result: result, rule: rule, profile: .light, now: now)

        #expect(classified.safety == .review)
        #expect(classified.confidence == 80)
        #expect(classified.explanation == "Original explanation")
        #expect(!classified.wasOverridden)
    }

    @Test("Returns base safety when no overrides defined")
    func noOverridesDefined() {
        let rule = makeRule(safety: .safe, confidence: 95)
        let result = makeResult()

        let classified = classifier.classify(result: result, rule: rule, profile: .developer, now: now)

        #expect(classified.safety == .safe)
        #expect(!classified.wasOverridden)
    }

    // MARK: - Batch Classification

    @Test("Batch classify processes all results")
    func batchClassify() {
        let rule = makeRule(safety: .safe, confidence: 95)
        let results = [
            (result: makeResult(), rule: rule),
            (result: makeResult(), rule: rule),
        ]

        let classified = classifier.classify(results: results, profile: .developer, now: now)

        #expect(classified.count == 2)
        #expect(classified.allSatisfy { $0.safety == .safe })
    }

    // MARK: - Nil lastAccessed

    @Test("Override does not apply when lastAccessed is nil")
    func nilLastAccessedNoOverride() {
        let rule = makeRule(
            safety: .review,
            overrides: [
                SafetyOverride(
                    condition: "age > 30d",
                    safety: .safe,
                    profiles: []
                ),
            ]
        )
        let result = makeResult(lastAccessed: nil)

        let classified = classifier.classify(result: result, rule: rule, profile: .developer, now: now)

        #expect(classified.safety == .review)
        #expect(!classified.wasOverridden)
    }
}
