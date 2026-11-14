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
        #expect(all[0].autoUpdates)
        #expect(all[1].appNames == ["Renamed.app"])
        #expect(all[1].quitBundleIDs == ["com.test.renamed"])
        #expect(all[1].sha256 == nil)
        #expect(all[1].hasVariations)
        #expect(all[2].quitBundleIDs == ["com.a", "com.b"])
        #expect(all[2].hasPkg)
    }

    private func app(_ file: String, _ id: String) -> InstalledApp {
        InstalledApp(bundleID: id, name: file, url: URL(fileURLWithPath: "/Applications/\(file)"))
    }

    @Test func matcherFilenameAndQuitRules() {
        let matcher = HomebrewCaskMatcher(entries: [
            HomebrewCaskEntry(token: "plain", version: "1", appNames: ["Plain.app"]),
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
            HomebrewCaskEntry(token: "a", version: "1", appNames: ["Dup.app"]),
            HomebrewCaskEntry(token: "b", version: "1", appNames: ["Dup.app"]),
        ])
        #expect(matcher.match(app("Dup.app", "x")) == nil)
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
        let source = HomebrewCaskSource(index: HomebrewCaskIndex(http: http, cacheDirectory: dir), hostIsArm64: true)
        let app = InstalledApp(
            bundleID: "com.test.renamed",
            name: "Renamed",
            url: URL(fileURLWithPath: "/Applications/Renamed.app"),
            shortVersion: "2.0",
            buildVersion: "1"
        )
        guard case .found(let candidate) = await source.lookUp([app])[app.bundleID] else {
            Issue.record("expected the renamed cask to match")
            return
        }
        #expect(candidate.version.build == nil)
        #expect(!candidate.version.isNewer(than: app.version))
    }
}
