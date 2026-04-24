import Darwin
import Foundation
import Testing
@testable import GargantuaCore

@Suite("NativeScanAdapter")
struct NativeScanAdapterTests {

    // MARK: - Fixture helpers

    private static func makeFixture() throws -> FixtureTree {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeScanAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: Self.realpath(raw.path) ?? raw.path, isDirectory: true)
        return FixtureTree(root: root)
    }

    private static func realpath(_ path: String) -> String? {
        guard let cstr = Darwin.realpath(path, nil) else { return nil }
        defer { free(cstr) }
        return String(cString: cstr)
    }

    private static func rule(
        id: String,
        name: String,
        paths: [String],
        pattern: String? = nil,
        exclude: [String] = [],
        skipIfProcessRunning: [String] = [],
        presenceGuards: [RulePresenceGuard] = [],
        contentGuards: [RuleContentGuard] = [],
        matchFilters: [String] = [],
        safety: SafetyLevel = .safe,
        category: String,
        tags: [String] = []
    ) -> ScanRule {
        ScanRule(
            id: id,
            name: name,
            paths: paths,
            pattern: pattern,
            exclude: exclude,
            skipIfProcessRunning: skipIfProcessRunning,
            presenceGuards: presenceGuards,
            contentGuards: contentGuards,
            matchFilters: matchFilters,
            safety: safety,
            confidence: 90,
            explanation: "Test cleanup rule",
            source: SourceAttribution(name: "Test Fixture"),
            regenerates: true,
            category: category,
            tags: tags
        )
    }

    private final class FixtureTree {
        let root: URL

        init(root: URL) {
            self.root = root
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
        func makeFile(_ relative: String, byteCount: Int = 128) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0x1, count: byteCount).write(to: url)
            return url
        }
    }

    private struct StubProcessChecker: RunningProcessChecking {
        let running: Set<String>

        func isRunning(identifier: String) -> Bool {
            running.contains(identifier)
        }
    }

    // MARK: - Profile scoping

    @Test("Dev Purge scans only dev, Docker, and Homebrew categories while Light excludes dev rules")
    func profileScoping() async throws {
        let fixture = try Self.makeFixture()
        let nodeModules = try fixture.makeFile("project/node_modules/package.json")
            .deletingLastPathComponent()
        let dockerCache = try fixture.makeFile("docker/cache/layer.bin")
            .deletingLastPathComponent()
        let homebrewCache = try fixture.makeFile("homebrew/cache/bottle.tar.gz")
            .deletingLastPathComponent()
        let downloads = try fixture.makeFile("Downloads/tool.dmg")
            .deletingLastPathComponent()

        let rules = [
            Self.rule(
                id: "node_modules",
                name: "Node Modules",
                paths: [nodeModules.path],
                safety: .review,
                category: "dev_artifacts"
            ),
            Self.rule(
                id: "docker_cache",
                name: "Docker Cache",
                paths: [dockerCache.path],
                safety: .review,
                category: "docker"
            ),
            Self.rule(
                id: "homebrew_cache",
                name: "Homebrew Cache",
                paths: [homebrewCache.path],
                safety: .review,
                category: "homebrew"
            ),
            Self.rule(
                id: "installer_images",
                name: "Installer Images",
                paths: [downloads.path],
                pattern: "*.dmg",
                category: "installers"
            ),
        ]

        let devResults = try await NativeScanAdapter(rules: rules, profile: .devPurge).scan()
        #expect(Set(devResults.map(\.category)) == ["dev_artifacts", "docker", "homebrew"])

        let lightResults = try await NativeScanAdapter(rules: rules, profile: .light).scan()
        #expect(Set(lightResults.map(\.category)) == ["installers"])
        #expect(lightResults.map(\.path) == [downloads.appendingPathComponent("tool.dmg").path])
    }

    // MARK: - Result shaping

    @Test("Overlapping rules deduplicate by path")
    func crossRuleDeduplication() async throws {
        let fixture = try Self.makeFixture()
        let sharedCache = try fixture.makeFile("shared/cache/blob.bin")
            .deletingLastPathComponent()
        let profile = CleanupProfile(
            id: "test",
            name: "Test",
            description: "Test profile",
            categories: ["dev_artifacts", "docker"]
        )
        let rules = [
            Self.rule(
                id: "shared_dev_cache",
                name: "Shared Dev Cache",
                paths: [sharedCache.path],
                category: "dev_artifacts"
            ),
            Self.rule(
                id: "shared_docker_cache",
                name: "Shared Docker Cache",
                paths: [sharedCache.path],
                category: "docker"
            ),
        ]

        let results = try await NativeScanAdapter(rules: rules, profile: profile).scan()

        #expect(results.count == 1)
        #expect(results.first?.path == sharedCache.path)
    }

    @Test("rule.pattern filters children inside matched directories")
    func rulePatternFiltersChildren() async throws {
        let fixture = try Self.makeFixture()
        let downloads = try fixture.makeDir("Downloads")
        let dmg = try fixture.makeFile("Downloads/tool.dmg")
        try fixture.makeFile("Downloads/tool.pkg")
        try fixture.makeFile("Downloads/readme.txt")
        let rule = Self.rule(
            id: "installer_images",
            name: "Installer Images",
            paths: [downloads.path],
            pattern: "*.dmg",
            category: "installers"
        )

        let results = try await NativeScanAdapter(rules: [rule], profile: .light).scan()

        #expect(results.map(\.path) == [dmg.path])
        #expect(results.first?.name == "Installer Images — tool.dmg")
    }

    @Test("skip_if_process_running suppresses guarded cleanup rules")
    func processGuardSkipsRule() async throws {
        let fixture = try Self.makeFixture()
        let firefoxCache = try fixture.makeFile("Firefox/Profile/cache2/entry", byteCount: 64)
            .deletingLastPathComponent()
        let rule = Self.rule(
            id: "firefox_cache",
            name: "Firefox Cache",
            paths: [firefoxCache.path],
            skipIfProcessRunning: ["org.mozilla.firefox"],
            category: "browser_cache"
        )
        let profile = CleanupProfile(
            id: "browser",
            name: "Browser",
            description: "Browser cache",
            categories: ["browser_cache"]
        )

        let runningResults = try await NativeScanAdapter(
            rules: [rule],
            profile: profile,
            processChecker: StubProcessChecker(running: ["org.mozilla.firefox"])
        ).scan()
        let stoppedResults = try await NativeScanAdapter(
            rules: [rule],
            profile: profile,
            processChecker: StubProcessChecker(running: [])
        ).scan()

        #expect(runningResults.isEmpty)
        #expect(stoppedResults.map(\.path) == [firefoxCache.path])
    }

    @Test("presence and content guards skip protected app-specific caches")
    func presenceAndContentGuardsSkipCandidates() async throws {
        let fixture = try Self.makeFixture()
        let spotifyCache = try fixture.makeFile("Spotify/Storage/data.bin", byteCount: 64)
            .deletingLastPathComponent()
        try fixture.makeFile("Spotify/Storage/offline.bnk", byteCount: 16)
        let raycastCache = try fixture.makeFile("Raycast/Cache/blob.bin", byteCount: 64)
            .deletingLastPathComponent()
        try fixture.makeFile("Raycast/Cache/metadata.json", byteCount: 32)
        try #"{"feature":"clipboard_history"}"#.write(
            to: raycastCache.appendingPathComponent("metadata.json"),
            atomically: true,
            encoding: .utf8
        )
        let safeCache = try fixture.makeFile("Other/Cache/blob.bin", byteCount: 64)
            .deletingLastPathComponent()

        let profile = CleanupProfile(
            id: "apps",
            name: "Apps",
            description: "App caches",
            categories: ["app_cache"]
        )
        let rules = [
            Self.rule(
                id: "spotify_cache",
                name: "Spotify Cache",
                paths: [spotifyCache.path],
                presenceGuards: [RulePresenceGuard(path: "offline.bnk")],
                category: "app_cache"
            ),
            Self.rule(
                id: "raycast_cache",
                name: "Raycast Cache",
                paths: [raycastCache.path],
                contentGuards: [RuleContentGuard(path: "metadata.json", contains: ["clipboard_history"])],
                category: "app_cache"
            ),
            Self.rule(
                id: "safe_cache",
                name: "Safe Cache",
                paths: [safeCache.path],
                category: "app_cache"
            ),
        ]

        let results = try await NativeScanAdapter(rules: rules, profile: profile).scan()

        #expect(results.map(\.path) == [safeCache.path])
    }

    @Test("match_filters apply mtime age before surfacing results")
    func matchFiltersApplyBeforeResults() async throws {
        let fixture = try Self.makeFixture()
        let oldLog = try fixture.makeFile("Logs/old.log", byteCount: 64)
        let recentLog = try fixture.makeFile("Logs/recent.log", byteCount: 64)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-8 * 86_400)],
            ofItemAtPath: oldLog.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-1 * 86_400)],
            ofItemAtPath: recentLog.path
        )
        let rule = Self.rule(
            id: "old_logs",
            name: "Old Logs",
            paths: [oldLog.path, recentLog.path],
            matchFilters: ["mtime > 7d"],
            category: "system_logs"
        )
        let profile = CleanupProfile(
            id: "logs",
            name: "Logs",
            description: "Logs",
            categories: ["system_logs"]
        )

        let results = try await NativeScanAdapter(rules: [rule], profile: profile).scan()

        #expect(results.map(\.path) == [oldLog.path])
    }

    // MARK: - Progress and factory wiring

    @MainActor
    @Test("Path expansion cap warnings are recorded on ScanProgress")
    func capWarningsPropagateThroughProgress() async throws {
        let fixture = try Self.makeFixture()
        try fixture.makeDir("project-a/node_modules")
        try fixture.makeDir("project-b/node_modules")
        let rule = Self.rule(
            id: "node_modules",
            name: "Node Modules",
            paths: ["**/node_modules"],
            safety: .review,
            category: "dev_artifacts"
        )
        let progress = ScanProgress()
        let expander = PathExpander(
            limits: PathExpander.Limits(maxDepth: 8, maxEntries: 1, timeBudget: 30)
        )
        let adapter = NativeScanAdapter(
            rules: [rule],
            profile: .devPurge,
            scanRoots: [fixture.root],
            expander: expander
        )

        _ = try await adapter.scan(progress: progress)

        #expect(progress.errors.contains {
            $0.contains("Stopped scanning Node Modules: entries reached")
        })
    }

    @Test("loadDefaults honors scanRoots override")
    func loadDefaultsScanRootsOverride() throws {
        let fixture = try Self.makeFixture()
        let customRoots = [fixture.root]
        let adapter = try NativeScanAdapter.loadDefaults(profile: .devPurge, scanRoots: customRoots)
        let scanRoots = Mirror(reflecting: adapter).children
            .first { $0.label == "scanRoots" }?.value as? [URL]

        #expect(scanRoots?.map(\.path) == customRoots.map(\.path))
    }
}
