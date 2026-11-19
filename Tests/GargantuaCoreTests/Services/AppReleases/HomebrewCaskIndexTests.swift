import Foundation
import Testing
@testable import GargantuaCore

@Suite("Homebrew cask index")
struct HomebrewCaskIndexTests {
    private static let sample = """
    [
     {"token":"plain","name":["Plain"],"version":"1.0","url":"https://x.test/p.dmg","sha256":"abc","homepage":"https://x.test",
      "artifacts":[{"app":["Plain.app"],"target":"/Applications/Plain.app"}],"auto_updates":true,"deprecated":false,"disabled":false,"variations":{}},
     {"token":"renamed","version":"2.0,5","url":"https://x.test/r.zip","sha256":"no_check",
      "artifacts":[{"app":["Orig.app",{"target":"Renamed.app"}]},{"uninstall":[{"quit":"com.test.renamed"}]}],"variations":{"sonoma":{"url":"u"}}},
     {"token":"multi","version":"3","artifacts":[{"pkg":["M.pkg"]},{"uninstall":[{"quit":["com.a","com.b"]}]},{"app":["M.app"]}]},
     {"bogus":true}
    ]
    """

    private func entries() throws -> [HomebrewCaskEntry] { try HomebrewCaskEntry.decodeAll(from: Data(Self.sample.utf8)) }

    @Test func decodesEntries() throws {
        let all = try entries()
        #expect(all.map(\.token) == ["plain", "renamed", "multi"])
        #expect(all[0].appNames == ["Plain.app"])
        #expect(all[0].sha256 == "abc")
        #expect(all[1].appNames == ["Renamed.app"])
        #expect(all[1].quitBundleIDs == ["com.test.renamed"])
        #expect(all[1].sha256 == nil)
        #expect(!all[1].variations.isEmpty)
        #expect(all[2].quitBundleIDs == ["com.a", "com.b"])
        #expect(all[2].hasPkg)
    }

    private func app(_ file: String, _ id: String) -> InstalledApp {
        InstalledApp(bundleID: id, name: file, url: URL(fileURLWithPath: "/Applications/\(file)"))
    }

    @Test func matcherFilenameAndQuitRules() {
        let matcher = HomebrewCaskMatcher(entries: [
            HomebrewCaskEntry(token: "plain", version: "1", appNames: ["Plain.app"], referencedNames: ["any.id.plist"]),
            HomebrewCaskEntry(token: "q", version: "1", appNames: ["Q.app"], quitBundleIDs: ["com.q"]),
            HomebrewCaskEntry(token: "w", version: "1", appNames: ["W.app"], quitBundleIDs: ["com.w.*"]),
        ])
        #expect(matcher.match(app("plain.app", "any.id"))?.token == "plain")
        #expect(matcher.match(app("Q.app", "com.q"))?.token == "q")
        #expect(matcher.match(app("Q.app", "com.other")) == nil)
        #expect(matcher.match(app("W.app", "com.w.helper"))?.token == "w")
        #expect(matcher.match(app("Nope.app", "x")) == nil)
    }

    @Test func ambiguousMatchIsNil() {
        let matcher = HomebrewCaskMatcher(entries: [
            HomebrewCaskEntry(token: "a", version: "1", appNames: ["Dup.app"], referencedNames: ["com.x.dup"]),
            HomebrewCaskEntry(token: "b", version: "1", appNames: ["Dup.app"], referencedNames: ["com.x.dup.plist"]),
        ])
        #expect(matcher.match(app("Dup.app", "com.x.dup")) == nil)
    }

    // MARK: - Caskroom

    @Test("the Caskroom yields each cask's apps from the receipt or the newest cask JSON")
    func caskroomProbeReadsMetadata() throws {
        let prefix = try CaskroomFixture.makePrefix([
            "Caskroom/foo/.metadata/INSTALL_RECEIPT.json":
                #"{"uninstall_artifacts":[{"uninstall":[{"quit":"com.example.Foo"}]},{"app":["Foo.app"]}],"source":{"tap":"acme/tap"}}"#,
            "Caskroom/foo/.metadata/1.0/20250101000000.000/Casks/foo.json": "{}",
            "Caskroom/bar/.metadata/1.0/20240101000000.000/Casks/bar.json": #"{"artifacts":[{"app":["Old.app"]}]}"#,
            "Caskroom/bar/.metadata/2.0/20250101000000.000/Casks/bar.json":
                #"{"artifacts":[{"app":["Bar Beta.app",{"target":"Bar.app"}]}]}"#,
            "Caskroom/baz/.metadata/1.0/20250101000000.000/Casks/baz.rb": "cask \"baz\" do\nend\n",
        ])
        defer { try? FileManager.default.removeItem(at: prefix) }

        let casks = HomebrewCaskroomProbe(prefixes: [prefix.path]).installedCasks().sorted { $0.token < $1.token }

        #expect(casks == [
            HomebrewInstalledCask(token: "bar", appNames: ["Bar.app"]),
            HomebrewInstalledCask(token: "baz", appNames: nil),
            HomebrewInstalledCask(token: "foo", appNames: ["Foo.app"], quitBundleIDs: ["com.example.Foo"], tap: "acme/tap"),
        ])
    }

    @Test("the public index describes an owner only when it is the index's cask from homebrew/cask or an unknown tap")
    func publicIndexDescribesOwner() {
        let ownership = HomebrewCaskOwnership(casks: [
            HomebrewInstalledCask(token: "pub", tap: "Homebrew/Cask"),
            HomebrewInstalledCask(token: "old"),
            HomebrewInstalledCask(token: "third", tap: "acme/tap"),
        ])
        #expect(ownership.publicIndexDescribes(owner: "pub", indexToken: "pub"))
        #expect(ownership.publicIndexDescribes(owner: "old", indexToken: "old"))
        #expect(!ownership.publicIndexDescribes(owner: "third", indexToken: "third"))
        #expect(!ownership.publicIndexDescribes(owner: "pub", indexToken: "other"))
        #expect(!ownership.publicIndexDescribes(owner: "pub", indexToken: nil))

        let publicFirst = HomebrewCaskOwnership(casks: [
            HomebrewInstalledCask(token: "foo", tap: "homebrew/cask"),
            HomebrewInstalledCask(token: "foo", tap: "acme/tap"),
        ])
        let thirdFirst = HomebrewCaskOwnership(casks: [
            HomebrewInstalledCask(token: "foo", tap: "acme/tap"),
            HomebrewInstalledCask(token: "foo", tap: "homebrew/cask"),
        ])
        #expect(!publicFirst.publicIndexDescribes(owner: "foo", indexToken: "foo"))
        #expect(!thirdFirst.publicIndexDescribes(owner: "foo", indexToken: "foo"))
    }

    @Test("an installed cask owns the app it names, a quit list must include the app or its vendor, and unknown casks match by token")
    func caskOwnershipRules() {
        let ownership = HomebrewCaskOwnership(casks: [
            HomebrewInstalledCask(token: "foo", appNames: ["Foo.app"], quitBundleIDs: ["com.example.Foo"]),
            HomebrewInstalledCask(token: "bar", appNames: ["Bar.app"]),
            HomebrewInstalledCask(token: "baz-app", appNames: nil),
            HomebrewInstalledCask(token: "qux", appNames: ["Qux.app"], quitBundleIDs: ["com.example.QuxHelper"]),
            HomebrewInstalledCask(token: "wild", appNames: ["Wild.app"], quitBundleIDs: ["com.example.*"]),
        ])
        #expect(ownership.owner(of: app("Foo.app", "com.example.Foo"), indexToken: nil) == "foo")
        #expect(ownership.owner(of: app("Foo.app", "com.other.Foo"), indexToken: nil) == nil)
        #expect(ownership.owner(of: app("Qux.app", "com.example.Qux"), indexToken: nil) == "qux")
        #expect(ownership.owner(of: app("Qux.app", "org.other.Qux"), indexToken: nil) == nil)
        #expect(ownership.owner(of: app("Qux.app", "qux"), indexToken: nil) == nil)
        #expect(ownership.owner(of: app("Qux.app", "com.example"), indexToken: nil) == nil)
        #expect(ownership.owner(of: app("Wild.app", "com.example.Anything"), indexToken: nil) == "wild")
        #expect(ownership.owner(of: app("bar.app", "any.id"), indexToken: nil) == "bar")
        #expect(ownership.owner(of: app("Baz App.app", "any.id"), indexToken: nil) == "baz-app")
        #expect(ownership.owner(of: app("Other.app", "any.id"), indexToken: nil) == nil)
        #expect(ownership.owner(of: app("Other.app", "any.id"), indexToken: "bar") == "bar")
        #expect(ownership.owner(of: app("Other.app", "any.id"), indexToken: "not-installed") == nil)
    }

    private func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("cask-\(UUID().uuidString)") }

    private func okResponse() -> AppReleaseHTTPResponse {
        AppReleaseHTTPResponse(statusCode: 200, data: Data(Self.sample.utf8), etag: "\"e1\"")
    }

    @Test func freshCacheMakesNoRequest() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubAppReleaseHTTP { _, _ in AppReleaseHTTPResponse(statusCode: 200, data: Data(Self.sample.utf8), etag: "\"e1\"") }
        let index = HomebrewCaskIndex(http: http, cacheDirectory: dir, freshFor: 600)
        _ = try await index.entries()
        _ = try await HomebrewCaskIndex(http: http, cacheDirectory: dir, freshFor: 600).entries()
        #expect(http.requests.count == 1)
    }

    @Test func notModifiedReusesCache() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubAppReleaseHTTP { _, _ in AppReleaseHTTPResponse(statusCode: 200, data: Data(Self.sample.utf8), etag: "\"e1\"") }
        _ = try await HomebrewCaskIndex(http: http, cacheDirectory: dir, freshFor: 0).entries()
        http.setHandler { _, etag in AppReleaseHTTPResponse(statusCode: 304, data: Data(), etag: etag) }
        let again = try await HomebrewCaskIndex(http: http, cacheDirectory: dir, freshFor: 0).entries()
        #expect(again.count == 3)
        #expect(http.requests.last?.etag == "\"e1\"")
    }

    @Test func failureFallsBackToStaleCacheThenThrows() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let failing = StubAppReleaseHTTP { _, _ in throw AppReleaseHTTPError.network("offline") }
        await #expect(throws: (any Error).self) {
            _ = try await HomebrewCaskIndex(http: failing, cacheDirectory: dir, freshFor: 0).entries()
        }
        let http = StubAppReleaseHTTP { _, _ in AppReleaseHTTPResponse(statusCode: 200, data: Data(Self.sample.utf8)) }
        _ = try await HomebrewCaskIndex(http: http, cacheDirectory: dir, freshFor: 0).entries()
        let stale = try await HomebrewCaskIndex(http: failing, cacheDirectory: dir, freshFor: 0).entries()
        #expect(stale.count == 3)
    }

    @Test("a cask's build component is not compared with the app's CFBundleVersion")
    func caskBuildIgnored() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubAppReleaseHTTP { _, _ in AppReleaseHTTPResponse(statusCode: 200, data: Data(Self.sample.utf8)) }
        let source = HomebrewCaskSource(index: HomebrewCaskIndex(http: http, cacheDirectory: dir), host: HomebrewCaskHost(isArm64: true, macOSMajorVersion: 27))
        let app = InstalledApp(
            bundleID: "com.test.renamed",
            name: "Renamed",
            url: URL(fileURLWithPath: "/Applications/Renamed.app"),
            shortVersion: "2.0",
            buildVersion: "1"
        )
        guard case .found(let candidate) = await source.lookUp([app]).outcomes[app.bundleID] else {
            Issue.record("expected the renamed cask to match")
            return
        }
        #expect(candidate.version.build == nil)
        #expect(!candidate.version.isNewer(than: app.version))
    }

    // MARK: - Variations

    private static let variationsJSON = """
    {"arm64_sonoma":{"url":"https://x.test/old.dmg","sha256":"s1","version":"1.5"},"sequoia":{"url":"https://x.test/intel.dmg","sha256":"s2"},"x86_64_linux":{"url":"https://x.test/linux.tgz"}}
    """

    private static let variations: [String: HomebrewCaskVariation] = [
        "arm64_sonoma": HomebrewCaskVariation(url: "https://x.test/old.dmg", sha256: "s1", version: "1.5"),
        "sequoia": HomebrewCaskVariation(url: "https://x.test/intel.dmg", sha256: "s2", version: nil),
        "x86_64_linux": HomebrewCaskVariation(url: "https://x.test/linux.tgz", sha256: nil, version: nil),
    ]

    @Test func decodesVariationsRaw() throws {
        let json = #"[{"token":"v","version":"2.0","variations":\#(Self.variationsJSON)}]"#
        let entry = try #require(HomebrewCaskEntry.decodeAll(from: Data(json.utf8)).first)
        #expect(entry.variations == Self.variations)
    }

    @Test func resolvesVariationForHost() {
        var withTahoe = Self.variations
        withTahoe["tahoe"] = HomebrewCaskVariation(url: "https://x.test/t.dmg", sha256: "no_check", version: nil)
        let entry = HomebrewCaskEntry(token: "v", version: "2.0", url: "https://x.test/new.dmg", sha256: "top", variations: withTahoe)
        func release(_ arm: Bool, _ major: Int) -> [String?] {
            let r = entry.release(for: HomebrewCaskHost(isArm64: arm, macOSMajorVersion: major))
            return [r.url, r.sha256, r.version]
        }
        #expect(release(true, 27) == ["https://x.test/new.dmg", "top", "2.0"])
        #expect(release(true, 14) == ["https://x.test/old.dmg", "s1", "1.5"])
        #expect(release(false, 15) == ["https://x.test/intel.dmg", "s2", "2.0"])
        #expect(release(false, 26) == ["https://x.test/t.dmg", nil, "2.0"])
        #expect(release(false, 14) == ["https://x.test/new.dmg", "top", "2.0"])
        #expect(release(true, 28) == ["https://x.test/new.dmg", "top", "2.0"])
        #expect(release(false, 28) == [nil, "top", "2.0"])
        let plain = HomebrewCaskEntry(token: "p", version: "2.0", url: "https://x.test/new.dmg", sha256: "top")
        let r = plain.release(for: HomebrewCaskHost(isArm64: false, macOSMajorVersion: 15))
        #expect([r.url, r.sha256, r.version] == ["https://x.test/new.dmg", "top", "2.0"])
    }

    @Test func sourceResolvesHostVariation() async throws {
        let json = """
        [{"token":"v","version":"2.0","url":"https://x.test/new.dmg","sha256":"top","variations":\(Self.variationsJSON),
          "artifacts":[{"app":["V.app"]},{"zap":[{"trash":"~/Library/Caches/com.test.v"}]}]}]
        """
        let app = InstalledApp(
            bundleID: "com.test.v", name: "V", url: URL(fileURLWithPath: "/Applications/V.app"),
            shortVersion: "1.0", buildVersion: "1"
        )
        func candidate(_ host: HomebrewCaskHost) async throws -> AppReleaseCandidate {
            let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let http = StubAppReleaseHTTP { _, _ in AppReleaseHTTPResponse(statusCode: 200, data: Data(json.utf8)) }
            let source = HomebrewCaskSource(index: HomebrewCaskIndex(http: http, cacheDirectory: dir), host: host)
            guard case .found(let found) = await source.lookUp([app]).outcomes[app.bundleID] else {
                throw AppReleaseHTTPError.network("no candidate")
            }
            return found
        }
        let intel = try await candidate(HomebrewCaskHost(isArm64: false, macOSMajorVersion: 15))
        #expect(intel.downloadURL?.absoluteString == "https://x.test/intel.dmg")
        #expect(intel.sha256 == "s2")
        let old = try await candidate(HomebrewCaskHost(isArm64: true, macOSMajorVersion: 14))
        #expect(old.downloadURL?.absoluteString == "https://x.test/old.dmg")
        #expect(old.displayVersion == "1.5")
        #expect(old.sha256 == "s1")
    }

    // MARK: - Null checksums and depends_on

    private static func host(_ arm: Bool, _ major: Int) -> HomebrewCaskHost {
        HomebrewCaskHost(isArm64: arm, macOSMajorVersion: major)
    }

    @Test func decodesNullsAndDependsOn() throws {
        let json = """
        [{"token":"n","version":"1","depends_on":{"macos":{">=":["15"]},"arch":[{"type":"arm","bits":64}]},
          "variations":{"sequoia":{"sha256":null},"sonoma":{"url":"https://x.test/x64.dmg","sha256":null,"depends_on":{"macos":{}}}}}]
        """
        let entry = try #require(HomebrewCaskEntry.decodeAll(from: Data(json.utf8)).first)
        #expect(entry.dependsOn == HomebrewCaskRequirements(macOS: [">=": ["15"]], arch: ["arm"]))
        #expect(entry.variations["sequoia"]?.sha256IsNull == true)
        #expect(entry.variations["sequoia"]?.urlIsNull == false)
        #expect(entry.variations["sonoma"]?.sha256IsNull == true)
        #expect(entry.variations["sonoma"]?.urlIsNull == false)
        #expect(entry.variations["sonoma"]?.url == "https://x.test/x64.dmg")
        #expect(entry.variations["sonoma"]?.dependsOn == HomebrewCaskRequirements())
        #expect(entry.variations["sequoia"]?.dependsOn == nil)
    }

    @Test func nullChecksumGivesNoDownload() {
        let entry = HomebrewCaskEntry(
            token: "n", version: "1", url: "https://x.test/arm.dmg", sha256: "top",
            variations: [
                "sequoia": HomebrewCaskVariation(sha256IsNull: true),
                "sonoma": HomebrewCaskVariation(url: "https://x.test/x64.dmg", sha256IsNull: true),
            ]
        )
        #expect(entry.release(for: Self.host(false, 15)).url == nil)
        #expect(entry.release(for: Self.host(false, 14)).url == nil)
    }

    @Test func topLevelMacOSRequirement() {
        let entry = HomebrewCaskEntry(
            token: "m", version: "1", url: "https://x.test/a.dmg", sha256: "top",
            variations: ["arm64_sequoia": HomebrewCaskVariation(version: "1")],
            dependsOn: HomebrewCaskRequirements(macOS: [">=": ["15"]])
        )
        #expect(entry.release(for: Self.host(false, 14)).url == nil)
        #expect(entry.release(for: Self.host(true, 14)).url == nil)
        #expect(entry.release(for: Self.host(true, 15)).url == "https://x.test/a.dmg")
    }

    @Test func topLevelArchRequirement() {
        let entry = HomebrewCaskEntry(
            token: "a", version: "1", url: "https://x.test/a.dmg", sha256: "top",
            variations: ["arm64_sequoia": HomebrewCaskVariation(version: "1")],
            dependsOn: HomebrewCaskRequirements(arch: ["arm"])
        )
        #expect(entry.release(for: Self.host(false, 15)).url == nil)
        #expect(entry.release(for: Self.host(true, 15)).url == "https://x.test/a.dmg")
    }

    @Test func variationDependsOnReplacesTopLevel() {
        let entry = HomebrewCaskEntry(
            token: "r", version: "1", url: "https://x.test/a.dmg", sha256: "top",
            variations: ["sonoma": HomebrewCaskVariation(url: "https://x.test/old.dmg", dependsOn: HomebrewCaskRequirements())],
            dependsOn: HomebrewCaskRequirements(macOS: [">=": ["15"]])
        )
        #expect(entry.release(for: Self.host(false, 14)).url == "https://x.test/old.dmg")
    }

    @Test func equalityRequirementList() {
        let entry = HomebrewCaskEntry(
            token: "e", version: "1", url: "https://x.test/a.dmg", sha256: "top",
            variations: ["arm64_sonoma": HomebrewCaskVariation(version: "1")],
            dependsOn: HomebrewCaskRequirements(macOS: ["==": ["14", "15", "26", "27"]])
        )
        #expect(entry.release(for: Self.host(true, 14)).url == "https://x.test/a.dmg")
        #expect(entry.release(for: Self.host(true, 28)).url == nil)
    }

    @Test func cacheWithoutVariationsIsRefetched() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fetchedAt = ISO8601DateFormatter().string(from: Date())
        let old = """
        {"etag":"\\"old\\"","fetchedAt":"\(fetchedAt)","entries":[{"token":"plain","version":"1.0","appNames":["Plain.app"],\
        "quitBundleIDs":[],"hasPkg":false,"disabled":false,"hasVariations":true}]}
        """
        try Data(old.utf8).write(to: dir.appendingPathComponent("homebrew-casks.json"))
        let http = StubAppReleaseHTTP { _, _ in AppReleaseHTTPResponse(statusCode: 200, data: Data(Self.sample.utf8)) }
        let result = try await HomebrewCaskIndex(http: http, cacheDirectory: dir, freshFor: 600).entries()
        #expect(http.requests.count == 1)
        #expect(result.map(\.token) == ["plain", "renamed", "multi"])
    }
}

extension HomebrewCaskIndexTests {
    @Test("a shared app filename alone doesn't match a cask from another vendor")
    func filenameAloneIsNoMatch() {
        let matcher = HomebrewCaskMatcher(entries: [
            HomebrewCaskEntry(token: "motion", version: "1", appNames: ["Motion.app"], referencedNames: ["com.electron.motion.plist"]),
        ])
        #expect(matcher.match(app("Motion.app", "com.apple.motionapp")) == nil)
    }

    @Test("a cask with no quit IDs matches when it names the bundle ID or is installed")
    func caskEvidence() {
        let entry = HomebrewCaskEntry(
            token: "tool", version: "1", appNames: ["Tool.app"],
            referencedNames: ["com.acme.tool.savedstate", "team1234.com.acme.helper", "com.acme.wild*", "notcom.acme.other"]
        )
        let matcher = HomebrewCaskMatcher(entries: [entry])
        #expect(matcher.match(app("Tool.app", "com.Acme.Tool"))?.token == "tool")
        #expect(matcher.match(app("Tool.app", "com.acme.helper"))?.token == "tool")
        #expect(matcher.match(app("Tool.app", "com.acme.wild"))?.token == "tool")
        #expect(matcher.match(app("Tool.app", "com.acme.too")) == nil)
        #expect(matcher.match(app("Tool.app", "com.acme.other")) == nil)
        #expect(matcher.match(app("Tool.app", "tool")) == nil)
        #expect(matcher.match(app("Tool.app", "org.other.tool"), installedTokens: ["tool"])?.token == "tool")
        #expect(matcher.match(app("Tool.app", "org.other.tool"), installedTokens: ["else"]) == nil)
    }

    @Test("zap and uninstall names are kept only for casks with apps and no quit IDs")
    func referencedNamesDecoded() throws {
        let json = #"""
        [{"token":"a","version":"1","artifacts":[{"app":["A.app"]},
          {"uninstall":[{"launchctl":"com.a.agent"}]},
          {"zap":[{"trash":["~/Library/Application Support/com.A.App","~/Library/Preferences/com.a.app.plist","~/.config"]}]}]},
         {"token":"b","version":"1","artifacts":[{"app":["B.app"]},{"uninstall":[{"quit":"com.b"}]},{"zap":[{"trash":"~/Library/com.b.x"}]}]},
         {"token":"c","version":"1","artifacts":[{"binary":["c"]},{"zap":[{"trash":"~/Library/com.c.x"}]}]}]
        """#
        let all = try HomebrewCaskEntry.decodeAll(from: Data(json.utf8))
        #expect(all[0].referencedNames == ["com.a.agent", "com.a.app", "com.a.app.plist"])
        #expect(all[1].referencedNames.isEmpty)
        #expect(all[2].referencedNames.isEmpty)
    }

    @Test("an installed cask settles a tie between sibling casks")
    func installedCaskBreaksTie() {
        let quitting = HomebrewCaskMatcher(entries: [
            HomebrewCaskEntry(token: "tool", version: "1", appNames: ["Tool.app"], quitBundleIDs: ["com.acme.tool"]),
            HomebrewCaskEntry(token: "tool@tip", version: "2", appNames: ["Tool.app"], quitBundleIDs: ["com.acme.tool"]),
        ])
        let naming = HomebrewCaskMatcher(entries: [
            HomebrewCaskEntry(token: "tool", version: "1", appNames: ["Tool.app"], referencedNames: ["com.acme.tool.plist"]),
            HomebrewCaskEntry(token: "tool@tip", version: "2", appNames: ["Tool.app"], referencedNames: ["com.acme.tool.plist"]),
        ])
        for matcher in [quitting, naming] {
            let tool = app("Tool.app", "com.acme.tool")
            #expect(matcher.match(tool, installedTokens: ["tool@tip"])?.token == "tool@tip")
            #expect(matcher.match(tool) == nil)
            #expect(matcher.match(tool, installedTokens: ["tool", "tool@tip"]) == nil)
        }
    }

    @Test("a cache written before referenced names were kept is refetched")
    func cacheWithoutReferencedNamesIsRefetched() async throws {
        func requests(entryExtras: String) async throws -> Int {
            let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fetchedAt = ISO8601DateFormatter().string(from: Date())
            let cache = """
            {"etag":"\\"old\\"","fetchedAt":"\(fetchedAt)","entries":[{"token":"plain","version":"1.0","appNames":["Plain.app"],\
            "quitBundleIDs":[],"hasPkg":false,"disabled":false,"variations":{},"dependsOn":{"macOS":{},"arch":[]}\(entryExtras)}]}
            """
            try Data(cache.utf8).write(to: dir.appendingPathComponent("homebrew-casks.json"))
            let http = StubAppReleaseHTTP { _, _ in AppReleaseHTTPResponse(statusCode: 200, data: Data(Self.sample.utf8)) }
            _ = try await HomebrewCaskIndex(http: http, cacheDirectory: dir, freshFor: 600).entries()
            return http.requests.count
        }
        #expect(try await requests(entryExtras: #","referencedNames":[]"#) == 0)
        #expect(try await requests(entryExtras: "") == 1)
    }

    @Test("a cask version with the installed build written into it is not an update")
    func foldedBuildIsInstalledRelease() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        [{"token":"folded","version":"3.5.2.1","url":"https://x.test/f.dmg","sha256":"abc",
          "artifacts":[{"app":["Folded.app"]},{"zap":[{"trash":"~/Library/Caches/com.test.folded"}]}],"variations":{}}]
        """
        let http = StubAppReleaseHTTP { _, _ in AppReleaseHTTPResponse(statusCode: 200, data: Data(json.utf8)) }
        let source = HomebrewCaskSource(index: HomebrewCaskIndex(http: http, cacheDirectory: dir), host: HomebrewCaskHost(isArm64: true, macOSMajorVersion: 27))
        func folded(short: String, build: String) -> InstalledApp {
            InstalledApp(
                bundleID: "com.test.folded",
                name: "Folded",
                url: URL(fileURLWithPath: "/Applications/Folded.app"),
                shortVersion: short,
                buildVersion: build
            )
        }
        for (app, isUpdate) in [(folded(short: "3.5.2", build: "1"), false), (folded(short: "3.5.1", build: "9"), true)] {
            guard case .found(let candidate) = await source.lookUp([app]).outcomes[app.bundleID] else {
                Issue.record("expected the cask to match")
                return
            }
            #expect(candidate.version.isNewer(than: app.version) == isUpdate)
            #expect(candidate.displayVersion == "3.5.2.1")
        }
    }
}
