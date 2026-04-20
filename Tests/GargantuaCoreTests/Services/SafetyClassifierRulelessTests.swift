import Foundation
import Testing
@testable import GargantuaCore

/// Tests for the rule-less `SafetyClassifier.classify(result:ruleOverrides:profile:now:)`
/// overload used by adapters (`CzkawkaAdapter`, `FclonesAdapter`) whose Trust
/// Layer defaults live in code rather than in YAML `ScanRule` files.
@Suite("SafetyClassifier (rule-less overload)")
struct SafetyClassifierRulelessTests {
    let classifier = SafetyClassifier()
    let now = Date()

    private func makeResult(
        safety: SafetyLevel,
        confidence: Int,
        explanation: String,
        lastAccessed: Date?
    ) -> ScanResult {
        ScanResult(
            id: "ruleless_001",
            name: "Item",
            path: "/tmp/item",
            size: 1024,
            safety: safety,
            confidence: confidence,
            explanation: explanation,
            source: SourceAttribution(name: "Czkawka"),
            lastAccessed: lastAccessed,
            category: "big_files"
        )
    }

    @Test("Returns base classification when no overrides match")
    func noMatch() {
        let result = makeResult(
            safety: .review,
            confidence: 50,
            explanation: "Flagged by czkawka.",
            lastAccessed: now.addingTimeInterval(-2 * 86400)
        )

        let classified = classifier.classify(result: result, profile: .light, now: now)

        #expect(classified.safety == .review)
        #expect(classified.confidence == 50)
        #expect(classified.explanation == "Flagged by czkawka.")
        #expect(!classified.wasOverridden)
    }

    @Test("Developer profile: 30+ day items downgrade to safe")
    func developerAgeOverride() {
        let result = makeResult(
            safety: .review,
            confidence: 50,
            explanation: "Unusually large file.",
            lastAccessed: now.addingTimeInterval(-45 * 86400)
        )

        let classified = classifier.classify(result: result, profile: .developer, now: now)

        #expect(classified.safety == .safe)
        #expect(classified.confidence == 95)
        #expect(classified.explanation.contains("Unusually large file."))
        #expect(classified.wasOverridden)
    }

    @Test("Adapter-supplied override takes precedence over profile-level")
    func adapterOverridePrecedence() {
        let result = makeResult(
            safety: .review,
            confidence: 50,
            explanation: "Base",
            lastAccessed: now.addingTimeInterval(-45 * 86400)
        )
        let adapterOverrides = [
            SafetyOverride(
                condition: "age > 30d",
                safety: .review,
                confidence: 99,
                explanationSuffix: "Adapter override",
                profiles: ["developer"]
            ),
        ]

        let classified = classifier.classify(
            result: result,
            ruleOverrides: adapterOverrides,
            profile: .developer,
            now: now
        )

        #expect(classified.safety == .review)
        #expect(classified.confidence == 99)
        #expect(classified.explanation.contains("Adapter override"))
        #expect(classified.wasOverridden)
    }

    @Test("Nil lastAccessed leaves base classification untouched")
    func nilLastAccessed() {
        let result = makeResult(
            safety: .review,
            confidence: 60,
            explanation: "Base",
            lastAccessed: nil
        )

        let classified = classifier.classify(result: result, profile: .developer, now: now)

        #expect(classified.safety == .review)
        #expect(classified.confidence == 60)
        #expect(!classified.wasOverridden)
    }

    @Test("Recent files are unaffected by age override")
    func recentFilesUnchanged() {
        let result = makeResult(
            safety: .review,
            confidence: 60,
            explanation: "Base",
            lastAccessed: now.addingTimeInterval(-3 * 86400)
        )

        let classified = classifier.classify(result: result, profile: .developer, now: now)

        #expect(classified.safety == .review)
        #expect(classified.confidence == 60)
        #expect(!classified.wasOverridden)
    }
}
