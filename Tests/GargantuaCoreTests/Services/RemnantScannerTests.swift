import Darwin
import Foundation
import Testing
@testable import GargantuaCore

private final class FixtureTree {
    let root: URL

    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemnantScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let resolved = Self.realpath(raw.path) ?? raw.path
        root = URL(fileURLWithPath: resolved, isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func makeDir(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func makeFile(_ relative: String, contents: String = "x") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func realpath(_ path: String) -> String? {
        guard let cstr = Darwin.realpath(path, nil) else { return nil }
        defer { free(cstr) }
        return String(cString: cstr)
    }
}

@Suite("RemnantScanner")
struct RemnantScannerTests {

    private static func app(bundlePath: String = "/Applications/Google Chrome.app") -> AppInfo {
        AppInfo(
            bundleID: "com.google.Chrome",
            name: "Google Chrome",
            bundlePath: bundlePath,
            lastUsedDate: Date(timeIntervalSince1970: 1_700_000_000),
            teamIdentifier: "EQHXZ8M8AV"
        )
    }

    @Test("Expands placeholders without escaping spaces or punctuation in appName")
    func expandsPlaceholders() {
        let app = AppInfo(
            bundleID: "com.example.Writer",
            name: "Writer Pro+ Beta",
            bundlePath: "/Applications/Writer.app",
            teamIdentifier: "TEAM123"
        )

        let expanded = RemnantScanner.expand(
            template: "/tmp/{teamID}/{bundleID}/{appName}",
            for: app
        )

        #expect(expanded == "/tmp/TEAM123/com.example.Writer/Writer Pro+ Beta")
    }

    @Test("Skips templates requiring teamID when app has no team identifier")
    func missingTeamIDSkipsTemplate() {
        let app = AppInfo(bundleID: "com.example.NoTeam", name: "No Team", bundlePath: "/NoTeam.app")
        #expect(RemnantScanner.expand(template: "/tmp/{teamID}/{bundleID}", for: app) == nil)
    }

    @Test("App name variant expansion includes Mole-style safe variants")
    func appNameVariantExpansion() {
        let app = AppInfo(
            bundleID: "com.google.Chrome",
            name: "Google Chrome Beta",
            displayName: "Google Chrome Beta",
            bundlePath: "/Applications/Google Chrome Beta.app"
        )

        let variants = RemnantScanner.appNameVariants(for: app)
        let expanded = RemnantScanner.expandAll(template: "/tmp/{appNameVariant}", for: app)

        #expect(variants.contains("Google Chrome Beta"))
        #expect(variants.contains("GoogleChromeBeta"))
        #expect(variants.contains("Google-Chrome-Beta"))
        #expect(variants.contains("Google_Chrome_Beta"))
        #expect(variants.contains("google chrome beta"))
        #expect(variants.contains("googlechromebeta"))
        #expect(variants.contains("google-chrome-beta"))
        #expect(variants.contains("google_chrome_beta"))
        #expect(variants.contains("Google Chrome"))
        #expect(variants.contains("GoogleChrome"))
        #expect(variants.contains("google-chrome"))
        #expect(variants.contains("Chrome"))
        #expect(expanded.contains("/tmp/GoogleChrome"))
        #expect(expanded.contains("/tmp/google-chrome"))
        #expect(expanded.contains("/tmp/Chrome"))
    }

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

        let plan = RemnantScanner(rules: [rule]).plan(for: Self.app(), includeAppBundle: false)

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

        let plan = RemnantScanner(rules: [rule]).plan(for: Self.app(), includeAppBundle: false)

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
        ).plan(for: Self.app(), includeAppBundle: false)

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

        let plan = RemnantScanner(rules: [rule]).plan(for: Self.app(), includeAppBundle: false)

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

        let plan = RemnantScanner(rules: [rule]).plan(for: Self.app(), includeAppBundle: false)

        #expect(plan.remnants.map(\.path) == [match.path])
    }

    @Test("Includes optional app bundle when present")
    func includesAppBundle() throws {
        let fixture = try FixtureTree()
        let appBundle = try fixture.makeDir("Applications/Google Chrome.app")
        try fixture.makeFile("Applications/Google Chrome.app/Contents/Info.plist", contents: "plist")
        let app = Self.app(bundlePath: appBundle.path)

        let plan = RemnantScanner(rules: []).plan(for: app)

        #expect(plan.appBundle?.path == appBundle.path)
        #expect(plan.appBundle?.category == .other)
        #expect(plan.appBundle?.ruleID == "app_bundle")
        #expect(plan.totalBytes > 0)
    }
}

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
