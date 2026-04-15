import Foundation
import Testing
@testable import GargantuaCore

@Suite("SafetyClassifier")
struct SafetyClassifierTests {
    let classifier = SafetyClassifier()
    let now = Date()

    // MARK: - Test Fixtures

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

    // MARK: - Developer Profile Overrides

    @Test("Developer profile: node_modules >30d auto-classified as safe")
    func developerProfileNodeModules30d() {
        let rule = makeRule(
            safety: .review,
            confidence: 85,
            explanation: "npm dependencies",
            overrides: [
                SafetyOverride(
                    condition: "age > 30d",
                    safety: .safe,
                    confidence: 95,
                    explanationSuffix: "No project activity in 30+ days.",
                    profiles: ["developer"]
                ),
            ]
        )
        let result = makeResult(lastAccessed: now.addingTimeInterval(-31 * 86400))

        let classified = classifier.classify(result: result, rule: rule, profile: .developer, now: now)

        #expect(classified.safety == .safe)
        #expect(classified.confidence == 95)
        #expect(classified.explanation.contains("No project activity in 30+ days."))
        #expect(classified.wasOverridden)
    }

    @Test("Developer profile override does NOT apply to light profile")
    func developerOverrideNotOnLight() {
        let rule = makeRule(
            safety: .review,
            overrides: [
                SafetyOverride(
                    condition: "age > 30d",
                    safety: .safe,
                    confidence: 95,
                    profiles: ["developer"]
                ),
            ]
        )
        let result = makeResult(lastAccessed: now.addingTimeInterval(-31 * 86400))

        let classified = classifier.classify(result: result, rule: rule, profile: .light, now: now)

        #expect(classified.safety == .review)
        #expect(!classified.wasOverridden)
    }

    @Test("Developer profile override does NOT apply to recent files")
    func developerOverrideNotOnRecentFiles() {
        let rule = makeRule(
            safety: .review,
            overrides: [
                SafetyOverride(
                    condition: "age > 30d",
                    safety: .safe,
                    profiles: ["developer"]
                ),
            ]
        )
        let result = makeResult(lastAccessed: now.addingTimeInterval(-5 * 86400))

        let classified = classifier.classify(result: result, rule: rule, profile: .developer, now: now)

        #expect(classified.safety == .review)
        #expect(!classified.wasOverridden)
    }

    // MARK: - Deep Profile Overrides

    @Test("Deep profile: additional overrides for >7d items")
    func deepProfile7dOverride() {
        let rule = makeRule(
            safety: .review,
            confidence: 85,
            explanation: "Review item",
            overrides: [
                SafetyOverride(
                    condition: "age > 7d",
                    safety: .safe,
                    confidence: 90,
                    explanationSuffix: "Inactive for over a week.",
                    profiles: ["deep"]
                ),
            ]
        )
        let result = makeResult(lastAccessed: now.addingTimeInterval(-8 * 86400))

        let classified = classifier.classify(result: result, rule: rule, profile: .deep, now: now)

        #expect(classified.safety == .safe)
        #expect(classified.confidence == 90)
        #expect(classified.explanation.contains("Inactive for over a week."))
        #expect(classified.wasOverridden)
    }

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

    // MARK: - Profile-Level Overrides

    @Test("Profile-level overrides apply when no rule-level overrides match")
    func profileLevelOverride() {
        let rule = makeRule(safety: .review, confidence: 85, explanation: "Test item")
        let result = makeResult(lastAccessed: now.addingTimeInterval(-31 * 86400))

        // Developer profile has built-in age > 30d override
        let classified = classifier.classify(result: result, rule: rule, profile: .developer, now: now)

        #expect(classified.safety == .safe)
        #expect(classified.wasOverridden)
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

    // MARK: - Universal Profile Overrides

    @Test("Override with empty profiles applies to all profiles")
    func universalOverride() {
        let rule = makeRule(
            safety: .review,
            overrides: [
                SafetyOverride(
                    condition: "age > 30d",
                    safety: .safe,
                    profiles: []  // applies to all
                ),
            ]
        )
        let result = makeResult(lastAccessed: now.addingTimeInterval(-31 * 86400))

        // Should apply regardless of profile
        let lightResult = classifier.classify(result: result, rule: rule, profile: .light, now: now)
        let devResult = classifier.classify(result: result, rule: rule, profile: .developer, now: now)
        let deepResult = classifier.classify(result: result, rule: rule, profile: .deep, now: now)

        #expect(lightResult.wasOverridden)
        #expect(devResult.wasOverridden)
        #expect(deepResult.wasOverridden)
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
