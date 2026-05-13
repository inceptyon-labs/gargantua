import Foundation
import Testing
@testable import GargantuaCore

@Suite("RemnantScanner filters, scope, and sensitive-data preflight")
struct RemnantScannerFilterTests {

    @Test("Sensitive-data preflight downgrades safe remnant matches to review")
    func sensitiveDataPreflightDowngradesSafeRemnants() throws {
        let fixture = try FixtureTree()
        let cookies = try fixture.makeFile("Library/WebKit/com.example.Writer/Cookies.binarycookies", contents: "session")
        let rule = RemnantRule(
            id: "webkit_data",
            name: "WebKit Data",
            category: .webData,
            pathTemplates: [cookies.path],
            safety: .safe,
            confidence: 98,
            explanation: "Generated WebKit data.",
            source: SourceAttribution(name: "{appName}")
        )
        let app = AppInfo(
            bundleID: "com.example.Writer",
            name: "Writer",
            bundlePath: "/Applications/Writer.app"
        )

        let plan = RemnantScanner(rules: [rule]).plan(for: app, includeAppBundle: false)

        #expect(plan.remnants.count == 1)
        #expect(plan.remnants[0].safety == .review)
        #expect(plan.remnants[0].confidence == 80)
        #expect(plan.remnants[0].explanation.contains("cookies"))
        #expect(plan.remnants[0].tags.contains("sensitive_preflight"))
    }

    @Test("Applies rule scope before scanning")
    func appliesRuleScope() throws {
        let fixture = try FixtureTree()
        try fixture.makeFile("Library/Caches/com.google.Chrome/cache.db", contents: "abcdef")
        let rule = RemnantRule(
            id: "firefox_only",
            name: "Firefox Only",
            category: .caches,
            pathTemplates: [fixture.root.appendingPathComponent("Library/Caches/{bundleID}").path],
            confidence: 90,
            explanation: "Scoped rule.",
            source: SourceAttribution(name: "{appName}"),
            appliesTo: AppScope(bundleIDs: ["org.mozilla.firefox"])
        )

        let plan = RemnantScanner(rules: [rule]).plan(for: chromeApp(), includeAppBundle: false)

        #expect(plan.remnants.isEmpty)
    }

    @Test("Uses PathExpander glob semantics and excludes matching paths")
    func globAndExclude() throws {
        let fixture = try FixtureTree()
        let keep = try fixture.makeDir("Profiles/Default/Google Chrome/Cache")
        try fixture.makeFile("Profiles/Default/Google Chrome/Cache/data", contents: "keep")
        try fixture.makeDir("Profiles/Default/Google Chrome/Cache/backup")
        try fixture.makeFile("Profiles/Default/Google Chrome/Cache/backup/data", contents: "skip")
        let other = try fixture.makeDir("Profiles/Beta/Google Chrome/Cache")
        try fixture.makeFile("Profiles/Beta/Google Chrome/Cache/data", contents: "other")
        let rule = RemnantRule(
            id: "profile_cache",
            name: "Profile Cache",
            category: .caches,
            pathTemplates: [fixture.root.appendingPathComponent("Profiles/**/{appName}/Cache").path],
            exclude: ["*/backup"],
            confidence: 95,
            explanation: "Profile caches.",
            source: SourceAttribution(name: "{appName}")
        )

        let plan = RemnantScanner(
            rules: [rule],
            scanRoots: [fixture.root],
            expander: PathExpander(limits: .init(maxDepth: 8, maxEntries: 10_000, timeBudget: 5))
        ).plan(for: chromeApp(), includeAppBundle: false)

        #expect(Set(plan.remnants.map(\.path)) == [keep.path, other.path])
        #expect(plan.remnants.allSatisfy { !$0.path.contains("/backup") })
    }

    @Test("Excludes filter children when a literal directory is enumerated")
    func literalDirectoryExcludes() throws {
        let fixture = try FixtureTree()
        let support = try fixture.makeDir("Library/Application Support/Google Chrome")
        let keep = try fixture.makeFile("Library/Application Support/Google Chrome/state.db", contents: "keep")
        try fixture.makeFile("Library/Application Support/Google Chrome/CrashpadMetrics.pma", contents: "skip")
        let rule = RemnantRule(
            id: "support_files",
            name: "Support Files",
            category: .supportFiles,
            pathTemplates: [support.path],
            exclude: ["Crashpad*"],
            confidence: 90,
            explanation: "Support files.",
            source: SourceAttribution(name: "{appName}")
        )

        let plan = RemnantScanner(rules: [rule]).plan(for: chromeApp(), includeAppBundle: false)

        #expect(plan.remnants.map(\.path) == [keep.path])
    }

    @Test("Pattern enumerates child files and missing paths are graceful")
    func patternAndMissingPaths() throws {
        let fixture = try FixtureTree()
        let prefs = try fixture.makeDir("Library/Preferences")
        let match = try fixture.makeFile("Library/Preferences/com.google.Chrome.plist", contents: "prefs")
        try fixture.makeFile("Library/Preferences/other.txt", contents: "skip")
        let rule = RemnantRule(
            id: "prefs",
            name: "Preferences",
            category: .preferences,
            pathTemplates: [
                prefs.path,
                fixture.root.appendingPathComponent("missing").path,
            ],
            pattern: "{bundleID}.plist",
            confidence: 85,
            explanation: "Preferences.",
            source: SourceAttribution(name: "{appName}")
        )

        let plan = RemnantScanner(rules: [rule]).plan(for: chromeApp(), includeAppBundle: false)

        #expect(plan.remnants.map(\.path) == [match.path])
    }
}
