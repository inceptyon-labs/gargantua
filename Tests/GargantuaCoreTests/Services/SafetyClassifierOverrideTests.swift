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

@Suite("SafetyClassifier override shape: explanation, confidence, precedence")
struct SafetyClassifierOverrideTests {
    let classifier = SafetyClassifier()
    let now = Date()

    // MARK: - Override Explanation

    @Test("Override appends explanation_suffix to base explanation")
    func explanationSuffix() {
        let rule = makeRule(
            safety: .review,
            explanation: "npm dependencies.",
            overrides: [
                SafetyOverride(
                    condition: "age > 30d",
                    safety: .safe,
                    explanationSuffix: "Restore with package manager.",
                    profiles: []
                ),
            ]
        )
        let result = makeResult(lastAccessed: now.addingTimeInterval(-31 * 86400))

        let classified = classifier.classify(result: result, rule: rule, profile: .developer, now: now)

        #expect(classified.explanation == "npm dependencies. Restore with package manager.")
    }

    @Test("Override without explanation_suffix preserves base explanation")
    func noExplanationSuffix() {
        let rule = makeRule(
            safety: .review,
            explanation: "Base explanation",
            overrides: [
                SafetyOverride(
                    condition: "age > 30d",
                    safety: .safe,
                    profiles: []
                ),
            ]
        )
        let result = makeResult(lastAccessed: now.addingTimeInterval(-31 * 86400))

        let classified = classifier.classify(result: result, rule: rule, profile: .developer, now: now)

        #expect(classified.explanation == "Base explanation")
    }

    // MARK: - Override Confidence

    @Test("Override with confidence replaces base confidence")
    func overrideConfidence() {
        let rule = makeRule(
            confidence: 80,
            overrides: [
                SafetyOverride(
                    condition: "age > 30d",
                    safety: .safe,
                    confidence: 95,
                    profiles: []
                ),
            ]
        )
        let result = makeResult(lastAccessed: now.addingTimeInterval(-31 * 86400))

        let classified = classifier.classify(result: result, rule: rule, profile: .developer, now: now)

        #expect(classified.confidence == 95)
    }

    @Test("Override without confidence uses base confidence")
    func overrideFallsBackToBaseConfidence() {
        let rule = makeRule(
            confidence: 80,
            overrides: [
                SafetyOverride(
                    condition: "age > 30d",
                    safety: .safe,
                    profiles: []
                ),
            ]
        )
        let result = makeResult(lastAccessed: now.addingTimeInterval(-31 * 86400))

        let classified = classifier.classify(result: result, rule: rule, profile: .developer, now: now)

        #expect(classified.confidence == 80)
    }

    // MARK: - Override Precedence

    @Test("First matching override wins")
    func firstMatchWins() {
        let rule = makeRule(
            safety: .review,
            overrides: [
                SafetyOverride(
                    condition: "age > 7d",
                    safety: .safe,
                    confidence: 90,
                    explanationSuffix: "7d override",
                    profiles: []
                ),
                SafetyOverride(
                    condition: "age > 30d",
                    safety: .safe,
                    confidence: 95,
                    explanationSuffix: "30d override",
                    profiles: []
                ),
            ]
        )
        let result = makeResult(lastAccessed: now.addingTimeInterval(-31 * 86400))

        let classified = classifier.classify(result: result, rule: rule, profile: .developer, now: now)

        // Both match, but first wins
        #expect(classified.confidence == 90)
        #expect(classified.explanation.contains("7d override"))
    }

    @Test("Rule-level overrides take precedence over profile-level overrides")
    func ruleLevelPrecedence() {
        let rule = makeRule(
            safety: .review,
            confidence: 85,
            explanation: "Base",
            overrides: [
                SafetyOverride(
                    condition: "age > 30d",
                    safety: .safe,
                    confidence: 99,
                    explanationSuffix: "Rule override",
                    profiles: ["developer"]
                ),
            ]
        )
        let result = makeResult(lastAccessed: now.addingTimeInterval(-31 * 86400))

        let classified = classifier.classify(result: result, rule: rule, profile: .developer, now: now)

        // Rule-level override should win over profile-level
        #expect(classified.confidence == 99)
        #expect(classified.explanation.contains("Rule override"))
    }
}
