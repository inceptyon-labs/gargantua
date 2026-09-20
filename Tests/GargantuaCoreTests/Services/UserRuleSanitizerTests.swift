import Foundation
import Testing
@testable import GargantuaCore

@Suite("UserRuleSanitizer")
struct UserRuleSanitizerTests {
    private func scanRule(
        id: String = "user_rule",
        safety: SafetyLevel,
        overrides: [SafetyOverride] = []
    ) -> ScanRule {
        ScanRule(
            id: id,
            name: "User Rule",
            paths: ["~/Library/Caches/com.example.app"],
            safety: safety,
            confidence: 90,
            explanation: "User-authored.",
            source: SourceAttribution(name: "Example"),
            category: "user_custom",
            safetyOverrides: overrides
        )
    }

    @Test("Floors safe to review; leaves review and protected intact")
    func floorSemantics() {
        #expect(UserRuleSanitizer.floor(.safe) == .review)
        #expect(UserRuleSanitizer.floor(.review) == .review)
        #expect(UserRuleSanitizer.floor(.protected_) == .protected_)
    }

    @Test("A user rule can never declare a one-click safe classification")
    func scanRuleSafeIsClamped() {
        let sanitized = UserRuleSanitizer.sanitize(scanRule(safety: .safe))
        #expect(sanitized.safety == .review)
    }

    @Test("Protected stays protected (clamp only raises floor, never lowers)")
    func scanRuleProtectedPreserved() {
        let sanitized = UserRuleSanitizer.sanitize(scanRule(safety: .protected_))
        #expect(sanitized.safety == .protected_)
    }

    @Test("Profile-scoped safety overrides are stripped from user rules")
    func scanRuleOverridesStripped() {
        let override = SafetyOverride(condition: "age > 30d", safety: .safe, profiles: ["developer"])
        let sanitized = UserRuleSanitizer.sanitize(scanRule(safety: .review, overrides: [override]))
        #expect(sanitized.safetyOverrides.isEmpty)
    }

    @Test("Remnant rule safety is floored to review")
    func remnantRuleClamped() {
        let rule = RemnantRule(
            id: "user_remnant",
            name: "Leftover",
            category: .caches,
            pathTemplates: ["~/Library/Caches/{bundleID}"],
            safety: .safe,
            confidence: 80,
            explanation: "User remnant.",
            source: SourceAttribution(name: "Example")
        )
        #expect(UserRuleSanitizer.sanitize(rule).safety == .review)
    }

    @Test("Command rule safety is floored to review")
    func commandRuleClamped() {
        let rule = CommandActionRule(
            id: "user_cmd",
            name: "Prune",
            tool: "pnpm",
            arguments: ["store", "prune"],
            safety: .safe,
            confidence: 80,
            explanation: "User command.",
            category: CommandActionRuleCategory.developer,
            source: SourceAttribution(name: "pnpm")
        )
        #expect(UserRuleSanitizer.sanitize(rule).safety == .review)
    }

    @Test("Merge drops a user rule whose id collides with a bundled rule")
    func mergeDropsBundledCollision() {
        let bundled = [scanRule(id: "shared", safety: .safe)]
        let user = [scanRule(id: "shared", safety: .safe)]
        let result = UserRuleSanitizer.merge(bundled: bundled, user: user, sanitizing: UserRuleSanitizer.sanitize)

        #expect(result.rules.count == 1)
        #expect(result.droppedIDs == ["shared"])
        // The surviving rule is the untouched bundled one (still safe).
        #expect(result.rules[0].safety == .safe)
    }

    @Test("Classifier caps a user rule at review even when a profile override promotes to safe")
    func classifierEnforcesFloorAgainstProfileOverride() {
        // Sanitized user rule: base review, own overrides stripped, origin-tagged.
        let userRule = UserRuleSanitizer.sanitize(scanRule(safety: .safe))
        #expect(userRule.tags.contains(UserRuleSanitizer.originTag))

        // A profile that blanket-promotes anything to safe — the exact bypass.
        let promotingProfile = CleanupProfile(
            id: "developer",
            name: "Developer",
            description: "Test",
            categories: ["user_custom"],
            safetyOverrides: [SafetyOverride(condition: "age > 0d", safety: .safe)]
        )
        let result = ScanResult(
            id: "item",
            name: "Item",
            path: "/tmp/item",
            size: 1,
            safety: .review,
            confidence: 90,
            explanation: "x",
            source: SourceAttribution(name: "Example"),
            lastAccessed: Date(timeIntervalSince1970: 0),
            category: "user_custom"
        )

        let classified = SafetyClassifier().classify(result: result, rule: userRule, profile: promotingProfile)
        #expect(classified.safety == .review)
    }

    @Test("Merge sanitizes accepted user rules and dedupes user-internal id clashes")
    func mergeSanitizesAndDedupesUser() {
        let bundled = [scanRule(id: "bundled_a", safety: .safe)]
        let user = [
            scanRule(id: "user_a", safety: .safe),
            scanRule(id: "user_a", safety: .safe), // internal duplicate
        ]
        let result = UserRuleSanitizer.merge(bundled: bundled, user: user, sanitizing: UserRuleSanitizer.sanitize)

        #expect(result.rules.count == 2) // bundled_a + first user_a
        #expect(result.droppedIDs == ["user_a"])
        let accepted = result.rules.first { $0.id == "user_a" }
        #expect(accepted?.safety == .review) // sanitized
    }
}
