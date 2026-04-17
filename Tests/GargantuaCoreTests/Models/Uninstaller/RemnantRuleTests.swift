import Foundation
import Testing
@testable import GargantuaCore

@Suite("RemnantRule")
struct RemnantRuleTests {

    static let sample = RemnantRule(
        id: "generic_caches",
        name: "Caches",
        category: .caches,
        pathTemplates: ["~/Library/Caches/{bundleID}", "~/Library/Caches/{appName}"],
        confidence: 99,
        explanation: "Disposable cache data regenerated on next run.",
        source: SourceAttribution(name: "{appName}"),
        regenerates: true,
        tags: ["generic", "cache"]
    )

    @Test("Initializer sets all fields")
    func allFields() {
        let rule = Self.sample
        #expect(rule.id == "generic_caches")
        #expect(rule.name == "Caches")
        #expect(rule.category == .caches)
        #expect(rule.pathTemplates.count == 2)
        #expect(rule.pattern == nil)
        #expect(rule.exclude.isEmpty)
        #expect(rule.confidence == 99)
        #expect(rule.explanation.contains("cache"))
        #expect(rule.source.name == "{appName}")
        #expect(rule.appliesTo == nil)
        #expect(rule.regenerates == true)
        #expect(rule.tags == ["generic", "cache"])
    }

    @Test("Omitting safety inherits the category default")
    func safetyInheritsFromCategory() {
        let rule = RemnantRule(
            id: "r",
            name: "n",
            category: .launchDaemons,
            pathTemplates: ["/Library/LaunchDaemons/{bundleID}.plist"],
            confidence: 80,
            explanation: "daemon",
            source: SourceAttribution(name: "test")
        )
        #expect(rule.safety == .protected_)
    }

    @Test("Explicit safety overrides the category default")
    func safetyExplicitOverride() {
        let rule = RemnantRule(
            id: "r",
            name: "n",
            category: .launchDaemons,
            pathTemplates: ["/Library/LaunchDaemons/{bundleID}.plist"],
            safety: .review,
            confidence: 80,
            explanation: "daemon",
            source: SourceAttribution(name: "test")
        )
        #expect(rule.safety == .review)
    }

    @Test("Codable round-trip preserves all fields including scope")
    func codableRoundTrip() throws {
        let rule = RemnantRule(
            id: "slack_specific",
            name: "Slack cookies",
            category: .cookies,
            pathTemplates: ["~/Library/Cookies/com.tinyspeck.slackmacgap.binarycookies"],
            pattern: "*.binarycookies",
            exclude: ["**/backup/**"],
            safety: .review,
            confidence: 85,
            explanation: "Slack session cookies",
            source: SourceAttribution(name: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
            appliesTo: AppScope(bundleIDs: ["com.tinyspeck.slackmacgap"]),
            regenerates: false,
            tags: ["slack", "cookies"]
        )

        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(RemnantRule.self, from: data)

        #expect(decoded.id == rule.id)
        #expect(decoded.category == .cookies)
        #expect(decoded.pathTemplates == rule.pathTemplates)
        #expect(decoded.pattern == "*.binarycookies")
        #expect(decoded.exclude == ["**/backup/**"])
        #expect(decoded.safety == .review)
        #expect(decoded.source.bundleID == "com.tinyspeck.slackmacgap")
        #expect(decoded.appliesTo?.bundleIDs == ["com.tinyspeck.slackmacgap"])
        #expect(decoded.tags == ["slack", "cookies"])
    }
}

@Suite("AppScope")
struct AppScopeTests {

    @Test("Empty allow-list matches all but excluded bundle IDs")
    func emptyAllowList() {
        let scope = AppScope(excludeBundleIDs: ["com.apple.Finder"])
        #expect(scope.matches(bundleID: "com.google.Chrome") == true)
        #expect(scope.matches(bundleID: "com.apple.Finder") == false)
    }

    @Test("Allow-list narrows match set")
    func allowList() {
        let scope = AppScope(bundleIDs: ["com.google.Chrome", "com.apple.Safari"])
        #expect(scope.matches(bundleID: "com.google.Chrome") == true)
        #expect(scope.matches(bundleID: "com.mozilla.firefox") == false)
    }

    @Test("Exclude overrides allow")
    func excludeWins() {
        let scope = AppScope(
            bundleIDs: ["com.google.Chrome"],
            excludeBundleIDs: ["com.google.Chrome"]
        )
        #expect(scope.matches(bundleID: "com.google.Chrome") == false)
    }

    @Test("Default scope matches anything")
    func defaultScope() {
        #expect(AppScope().matches(bundleID: "com.anything") == true)
    }
}

@Suite("RemnantRuleFile")
struct RemnantRuleFileTests {

    @Test("Container holds multiple rules")
    func holdsRules() {
        let file = RemnantRuleFile(rules: [RemnantRuleTests.sample])
        #expect(file.rules.count == 1)
        #expect(file.rules[0].id == "generic_caches")
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let file = RemnantRuleFile(rules: [RemnantRuleTests.sample])
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(RemnantRuleFile.self, from: data)
        #expect(decoded.rules.count == 1)
        #expect(decoded.rules[0].category == .caches)
    }
}
