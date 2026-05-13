import Foundation
import Testing
@testable import GargantuaCore

@Suite("RemnantScanner app packs")
struct RemnantScannerAppPackTests {

    @Test("App-pack rules win over generic rules for the same path")
    func appPackRulesWinOverGenericRules() throws {
        let fixture = try FixtureTree()
        let support = try fixture.makeDir("Library/Application Support/com.raycast.macos")
        let keptChild = try fixture.makeFile(
            "Library/Application Support/com.raycast.macos/state.db",
            contents: "state"
        )
        try fixture.makeFile(
            "Library/Application Support/com.raycast.macos/Raycast.sqlite",
            contents: "history"
        )
        let generic = RemnantRule(
            id: "generic_support",
            name: "Generic Support",
            category: .supportFiles,
            pathTemplates: [support.path],
            confidence: 92,
            explanation: "Generic support data.",
            source: SourceAttribution(name: "{appName}"),
            tags: ["generic"]
        )
        let appPack = RemnantRule(
            id: "raycast_support_state",
            name: "Raycast Support State",
            category: .supportFiles,
            pathTemplates: [support.path],
            exclude: ["Raycast.sqlite"],
            safety: .review,
            confidence: 72,
            explanation: "Curated Raycast support state.",
            source: SourceAttribution(name: "Raycast", bundleID: "com.raycast.macos"),
            appliesTo: AppScope(bundleIDs: ["com.raycast.macos"]),
            tags: ["app_pack", "raycast"]
        )
        let app = AppInfo(
            bundleID: "com.raycast.macos",
            name: "Raycast",
            bundlePath: "/Applications/Raycast.app"
        )

        let plan = RemnantScanner(rules: [generic, appPack]).plan(for: app, includeAppBundle: false)

        #expect(plan.remnants.count == 1)
        #expect(plan.remnants[0].path == keptChild.path)
        #expect(plan.remnants[0].ruleID == "raycast_support_state")
        #expect(plan.remnants[0].safety == .review)
        #expect(plan.remnants[0].confidence == 72)
    }

    @Test("Sensitive-data preflight still downgrades safe app-pack rows")
    func appPackSensitiveDataPreflightDowngradesSafeRows() throws {
        let fixture = try FixtureTree()
        let cookies = try fixture.makeFile(
            "Library/Application Support/com.raycast.macos/Cookies.binarycookies",
            contents: "session"
        )
        let rule = RemnantRule(
            id: "raycast_cookie_cache",
            name: "Raycast Cookie Cache",
            category: .caches,
            pathTemplates: [cookies.path],
            safety: .safe,
            confidence: 94,
            explanation: "Generated Raycast cache.",
            source: SourceAttribution(name: "Raycast", bundleID: "com.raycast.macos"),
            appliesTo: AppScope(bundleIDs: ["com.raycast.macos"]),
            regenerates: true,
            tags: ["app_pack", "raycast"]
        )
        let app = AppInfo(
            bundleID: "com.raycast.macos",
            name: "Raycast",
            bundlePath: "/Applications/Raycast.app"
        )

        let plan = RemnantScanner(rules: [rule]).plan(for: app, includeAppBundle: false)

        #expect(plan.remnants.count == 1)
        #expect(plan.remnants[0].safety == .review)
        #expect(plan.remnants[0].confidence == 80)
        #expect(plan.remnants[0].tags.contains("sensitive_preflight"))
        #expect(plan.remnants[0].explanation.contains("cookies"))
    }
}
