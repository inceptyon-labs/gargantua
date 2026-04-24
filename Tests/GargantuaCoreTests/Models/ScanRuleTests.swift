import Foundation
import Testing
@testable import GargantuaCore

@Suite("ScanRule")
struct ScanRuleTests {

    static let sampleRule = ScanRule(
        id: "chrome_cache",
        name: "Chrome Browser Cache",
        paths: ["~/Library/Caches/Google/Chrome"],
        pattern: "Cache/*",
        safety: .safe,
        confidence: 97,
        explanation: "Browser cache that Chrome rebuilds automatically",
        source: SourceAttribution(
            name: "Google Chrome",
            bundleID: "com.google.Chrome",
            verifySignature: true
        ),
        regenerates: true,
        regenerateCommand: "open -a 'Google Chrome'",
        category: "browser_cache",
        tags: ["browser", "cache", "chromium"]
    )

    @Test("All fields populated correctly")
    func allFields() {
        let rule = Self.sampleRule
        #expect(rule.id == "chrome_cache")
        #expect(rule.name == "Chrome Browser Cache")
        #expect(rule.paths == ["~/Library/Caches/Google/Chrome"])
        #expect(rule.pattern == "Cache/*")
        #expect(rule.exclude.isEmpty)
        #expect(rule.skipIfProcessRunning.isEmpty)
        #expect(rule.presenceGuards.isEmpty)
        #expect(rule.contentGuards.isEmpty)
        #expect(rule.matchFilters.isEmpty)
        #expect(rule.safety == .safe)
        #expect(rule.confidence == 97)
        #expect(rule.explanation == "Browser cache that Chrome rebuilds automatically")
        #expect(rule.source.name == "Google Chrome")
        #expect(rule.source.bundleID == "com.google.Chrome")
        #expect(rule.source.verifySignature == true)
        #expect(rule.regenerates == true)
        #expect(rule.regenerateCommand == "open -a 'Google Chrome'")
        #expect(rule.category == "browser_cache")
        #expect(rule.tags == ["browser", "cache", "chromium"])
        #expect(rule.safetyOverrides.isEmpty)
    }

    @Test("Default values for optional fields")
    func defaults() {
        let rule = ScanRule(
            id: "sys_logs",
            name: "System Logs",
            paths: ["/var/log"],
            safety: .review,
            confidence: 80,
            explanation: "System log files",
            source: SourceAttribution(name: "macOS"),
            category: "system_logs"
        )
        #expect(rule.pattern == nil)
        #expect(rule.exclude.isEmpty)
        #expect(rule.tags.isEmpty)
        #expect(rule.regenerates == false)
        #expect(rule.regenerateCommand == nil)
        #expect(rule.safetyOverrides.isEmpty)
        #expect(rule.skipIfProcessRunning.isEmpty)
        #expect(rule.presenceGuards.isEmpty)
        #expect(rule.contentGuards.isEmpty)
        #expect(rule.matchFilters.isEmpty)
    }

    @Test("Rule guards and match filters are stored")
    func guardsAndMatchFilters() {
        let rule = ScanRule(
            id: "spotify_cache",
            name: "Spotify Cache",
            paths: ["~/Library/Caches/com.spotify.client"],
            skipIfProcessRunning: ["com.spotify.client"],
            presenceGuards: [RulePresenceGuard(path: "Storage/offline.bnk")],
            contentGuards: [RuleContentGuard(path: "metadata.json", contains: ["offline"])],
            matchFilters: ["mtime > 7d"],
            safety: .safe,
            confidence: 90,
            explanation: "Spotify cache",
            source: SourceAttribution(name: "Spotify"),
            category: "app_cache"
        )

        #expect(rule.skipIfProcessRunning == ["com.spotify.client"])
        #expect(rule.presenceGuards == [RulePresenceGuard(path: "Storage/offline.bnk")])
        #expect(rule.contentGuards == [RuleContentGuard(path: "metadata.json", contains: ["offline"])])
        #expect(rule.matchFilters == ["mtime > 7d"])
    }

    @Test("Rule with safety overrides and condition expressions")
    func safetyOverrides() {
        let rule = ScanRule(
            id: "node_modules",
            name: "Node Modules",
            paths: ["~/Development/**/node_modules"],
            safety: .review,
            confidence: 85,
            explanation: "npm dependencies, restorable with npm install",
            source: SourceAttribution(name: "Node.js"),
            regenerates: true,
            regenerateCommand: "npm install",
            category: "dev_artifacts",
            safetyOverrides: [
                SafetyOverride(
                    condition: "age > 30d",
                    safety: .safe,
                    confidence: 95,
                    explanationSuffix: "No project activity in 30+ days.",
                    profiles: ["developer"]
                ),
                SafetyOverride(
                    condition: "age > 7d",
                    safety: .safe,
                    confidence: 90,
                    profiles: ["deep"]
                ),
            ]
        )
        #expect(rule.safetyOverrides.count == 2)
        #expect(rule.safetyOverrides[0].condition == "age > 30d")
        #expect(rule.safetyOverrides[0].profiles == ["developer"])
        #expect(rule.safetyOverrides[1].condition == "age > 7d")
        #expect(rule.safetyOverrides[1].profiles == ["deep"])
    }

    @Test("Source verification with bundle ID and signature")
    func sourceVerification() {
        let rule = ScanRule(
            id: "xcode_derived",
            name: "Xcode Derived Data",
            paths: ["~/Library/Developer/Xcode/DerivedData"],
            safety: .safe,
            confidence: 99,
            explanation: "Xcode build artifacts, fully regenerated on build",
            source: SourceAttribution(
                name: "Xcode",
                bundleID: "com.apple.dt.Xcode",
                verifySignature: true
            ),
            regenerates: true,
            regenerateCommand: "xcodebuild",
            category: "dev_artifacts"
        )
        #expect(rule.source.bundleID == "com.apple.dt.Xcode")
        #expect(rule.source.verifySignature == true)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(Self.sampleRule)
        let decoded = try decoder.decode(ScanRule.self, from: data)

        #expect(decoded.id == "chrome_cache")
        #expect(decoded.name == "Chrome Browser Cache")
        #expect(decoded.paths == ["~/Library/Caches/Google/Chrome"])
        #expect(decoded.pattern == "Cache/*")
        #expect(decoded.exclude.isEmpty)
        #expect(decoded.safety == .safe)
        #expect(decoded.confidence == 97)
        #expect(decoded.explanation == "Browser cache that Chrome rebuilds automatically")
        #expect(decoded.source.name == "Google Chrome")
        #expect(decoded.source.bundleID == "com.google.Chrome")
        #expect(decoded.source.verifySignature == true)
        #expect(decoded.regenerates == true)
        #expect(decoded.regenerateCommand == "open -a 'Google Chrome'")
        #expect(decoded.category == "browser_cache")
        #expect(decoded.tags == ["browser", "cache", "chromium"])
        #expect(decoded.skipIfProcessRunning.isEmpty)
        #expect(decoded.presenceGuards.isEmpty)
        #expect(decoded.contentGuards.isEmpty)
        #expect(decoded.matchFilters.isEmpty)
    }

    @Test("Codable round-trip preserves safety overrides")
    func codableWithOverrides() throws {
        let rule = ScanRule(
            id: "node_modules",
            name: "Node Modules",
            paths: ["~/Development/**/node_modules"],
            safety: .review,
            confidence: 85,
            explanation: "npm dependencies",
            source: SourceAttribution(name: "Node.js"),
            category: "dev_artifacts",
            safetyOverrides: [
                SafetyOverride(
                    condition: "age > 30d",
                    safety: .safe,
                    confidence: 95,
                    explanationSuffix: "Inactive project.",
                    profiles: ["developer", "deep"]
                ),
            ]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(rule)
        let decoded = try decoder.decode(ScanRule.self, from: data)

        #expect(decoded.safetyOverrides.count == 1)
        #expect(decoded.safetyOverrides[0].condition == "age > 30d")
        #expect(decoded.safetyOverrides[0].safety == .safe)
        #expect(decoded.safetyOverrides[0].confidence == 95)
        #expect(decoded.safetyOverrides[0].explanationSuffix == "Inactive project.")
        #expect(decoded.safetyOverrides[0].profiles == ["developer", "deep"])
    }
}

@Suite("RuleFile")
struct RuleFileTests {

    @Test("RuleFile contains multiple rules")
    func multipleRules() {
        let file = RuleFile(rules: [
            ScanRuleTests.sampleRule,
            ScanRule(
                id: "safari_cache",
                name: "Safari Cache",
                paths: ["~/Library/Caches/com.apple.Safari"],
                safety: .safe,
                confidence: 95,
                explanation: "Safari browser cache",
                source: SourceAttribution(name: "Safari", bundleID: "com.apple.Safari"),
                category: "browser_cache"
            ),
        ])
        #expect(file.rules.count == 2)
        #expect(file.rules[0].id == "chrome_cache")
        #expect(file.rules[1].id == "safari_cache")
    }

    @Test("RuleFile Codable round-trip")
    func codableRoundTrip() throws {
        let file = RuleFile(rules: [ScanRuleTests.sampleRule])

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(file)
        let decoded = try decoder.decode(RuleFile.self, from: data)

        #expect(decoded.rules.count == 1)
        #expect(decoded.rules[0].id == "chrome_cache")
    }
}
