import Foundation
import Testing
@testable import GargantuaCore

@Suite("RemnantScanner")
struct RemnantScannerTests {

    @Test("Scans literal templates and resolves remnant metadata")
    func scansLiteralTemplates() throws {
        let fixture = try FixtureTree()
        let cache = try fixture.makeFile("Library/Caches/com.google.Chrome/cache.db", contents: "abcdef")
        let rule = RemnantRule(
            id: "generic_caches",
            name: "Caches",
            category: .caches,
            pathTemplates: [fixture.root.appendingPathComponent("Library/Caches/{bundleID}").path],
            confidence: 99,
            explanation: "Disposable cache data.",
            source: SourceAttribution(name: "{appName}"),
            regenerates: true,
            tags: ["cache"]
        )

        let plan = RemnantScanner(rules: [rule]).plan(for: chromeApp(), includeAppBundle: false)

        #expect(plan.app.bundleID == "com.google.Chrome")
        #expect(plan.appBundle == nil)
        #expect(plan.remnants.count == 1)
        #expect(plan.remnants[0].path == cache.deletingLastPathComponent().path)
        #expect(plan.remnants[0].size >= 6)
        #expect(plan.remnants[0].source.name == "Google Chrome")
        #expect(plan.remnants[0].source.bundleID == "com.google.Chrome")
        #expect(plan.remnants[0].ruleID == "generic_caches")
        #expect(plan.remnants[0].lastAccessed != nil)
        #expect(plan.totalBytes == plan.remnants[0].size)
    }

    @Test("Variant templates find no-space app remnants")
    func variantTemplatesFindNoSpaceRemnants() throws {
        let fixture = try FixtureTree()
        let cache = try fixture.makeFile("Library/Caches/GoogleChrome/cache.db", contents: "abcdef")
        let rule = RemnantRule(
            id: "variant_caches",
            name: "Variant Caches",
            category: .caches,
            pathTemplates: [fixture.root.appendingPathComponent("Library/Caches/{appNameVariant}").path],
            confidence: 99,
            explanation: "Disposable cache data.",
            source: SourceAttribution(name: "{appName}")
        )
        let app = AppInfo(
            bundleID: "com.google.Chrome",
            name: "Google Chrome Beta",
            bundlePath: "/Applications/Google Chrome Beta.app"
        )

        let plan = RemnantScanner(rules: [rule]).plan(for: app, includeAppBundle: false)

        #expect(plan.remnants.map(\.path) == [cache.deletingLastPathComponent().path])
    }

    @Test("Variant templates find lowercase XDG remnants")
    func variantTemplatesFindLowercaseXDGRemnants() throws {
        let fixture = try FixtureTree()
        let config = try fixture.makeFile(".config/maestro-studio/config.json", contents: "settings")
        let data = try fixture.makeFile(".local/share/maestrostudio/state.db", contents: "state")
        let rule = RemnantRule(
            id: "xdg_state",
            name: "XDG State",
            category: .other,
            pathTemplates: [
                fixture.root.appendingPathComponent(".config/{appNameVariant}").path,
                fixture.root.appendingPathComponent(".local/share/{appNameVariant}").path,
            ],
            safety: .review,
            confidence: 72,
            explanation: "XDG app state.",
            source: SourceAttribution(name: "{appName}")
        )
        let app = AppInfo(
            bundleID: "com.maestro.studio",
            name: "Maestro Studio",
            bundlePath: "/Applications/Maestro Studio.app"
        )

        let plan = RemnantScanner(rules: [rule]).plan(for: app, includeAppBundle: false)

        #expect(Set(plan.remnants.map(\.path)) == [
            config.deletingLastPathComponent().path,
            data.deletingLastPathComponent().path,
        ])
        #expect(plan.remnants.allSatisfy { $0.safety == .review })
    }

    @Test("Bundle-derived glob templates find extension remnants")
    func bundleDerivedGlobTemplatesFindExtensionRemnants() throws {
        let fixture = try FixtureTree()
        let appScript = try fixture.makeFile(
            "Library/Application Scripts/5A4RE8SF68.com.tencent.xinWeChat/action.js"
        )
        let container = try fixture.makeFile(
            "Library/Containers/com.tencent.xinWeChat.WeChatMacShare/state.db"
        )
        let fileProvider = try fixture.makeFile(
            "Library/Application Support/FileProvider/com.tencent.xinWeChat.WeChatFileProviderExtension/data"
        )
        let groupContainer = try fixture.makeFile(
            "Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat/shared.db"
        )
        try fixture.makeFile("Library/Containers/com.tencent.otherapp.Helper/state.db")
        let app = AppInfo(
            bundleID: "com.tencent.xinWeChat",
            name: "WeChat",
            bundlePath: "/Applications/WeChat.app",
            teamIdentifier: "5A4RE8SF68"
        )
        let rules = [
            RemnantRule(
                id: "app_scripts",
                name: "Application Scripts",
                category: .other,
                pathTemplates: [
                    fixture.root.appendingPathComponent("Library/Application Scripts/*.{bundleID}*").path,
                ],
                safety: .review,
                confidence: 76,
                explanation: "App scripts.",
                source: SourceAttribution(name: "{appName}")
            ),
            RemnantRule(
                id: "app_extensions",
                name: "App Extensions",
                category: .containers,
                pathTemplates: [
                    fixture.root.appendingPathComponent("Library/Containers/{bundleID}.*").path,
                    fixture.root.appendingPathComponent("Library/Application Support/FileProvider/{bundleID}*").path,
                ],
                safety: .review,
                confidence: 78,
                explanation: "App extension containers.",
                source: SourceAttribution(name: "{appName}")
            ),
            RemnantRule(
                id: "group_variants",
                name: "Group Container Variants",
                category: .groupContainers,
                pathTemplates: [
                    fixture.root.appendingPathComponent("Library/Group Containers/*.{bundleID}").path,
                ],
                safety: .review,
                confidence: 72,
                explanation: "Group containers.",
                source: SourceAttribution(name: "{appName}")
            ),
        ]

        let plan = RemnantScanner(
            rules: rules,
            scanRoots: [fixture.root],
            expander: PathExpander(limits: .init(maxDepth: 8, maxEntries: 10_000, timeBudget: 5))
        ).plan(for: app, includeAppBundle: false)

        #expect(Set(plan.remnants.map(\.path)) == [
            appScript.deletingLastPathComponent().path,
            container.deletingLastPathComponent().path,
            fileProvider.deletingLastPathComponent().path,
            groupContainer.deletingLastPathComponent().path,
        ])
        #expect(plan.remnants.allSatisfy { $0.safety == .review })
        #expect(!plan.remnants.contains { $0.path.contains("otherapp") })
    }

    @Test("Includes optional app bundle when present")
    func includesAppBundle() throws {
        let fixture = try FixtureTree()
        let appBundle = try fixture.makeDir("Applications/Google Chrome.app")
        try fixture.makeFile("Applications/Google Chrome.app/Contents/Info.plist", contents: "plist")
        let app = chromeApp(bundlePath: appBundle.path)

        let plan = RemnantScanner(rules: []).plan(for: app)

        #expect(plan.appBundle?.path == appBundle.path)
        #expect(plan.appBundle?.category == .other)
        #expect(plan.appBundle?.ruleID == "app_bundle")
        #expect(plan.totalBytes > 0)
    }
}
