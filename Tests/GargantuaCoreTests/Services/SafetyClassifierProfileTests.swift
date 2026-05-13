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

@Suite("SafetyClassifier profile-driven and universal overrides")
struct SafetyClassifierProfileTests {
    let classifier = SafetyClassifier()
    let now = Date()

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

    // MARK: - Universal Profile Overrides

    @Test("Override with empty profiles applies to all profiles")
    func universalOverride() {
        let rule = makeRule(
            safety: .review,
            overrides: [
                SafetyOverride(
                    condition: "age > 30d",
                    safety: .safe,
                    profiles: [] // applies to all
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
}
