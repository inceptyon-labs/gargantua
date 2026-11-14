import Foundation
import Testing
@testable import GargantuaCore

@Suite("AppReleaseCheckService")
struct AppReleaseCheckServiceTests {
    private static let casks = """
    [{"token":"latest-app","version":"latest","url":"https://example.com/Latest.dmg","sha256":"no_check",
      "homepage":"https://example.com","artifacts":[{"app":["Latest.app"]}]}]
    """
    private static let appcast = """
    <?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
    <item><sparkle:shortVersionString>2.1</sparkle:shortVersionString><link>https://example.com/news</link>
    <enclosure url="https://example.com/Latest-2.1.zip"/></item></channel></rss>
    """

    /// One app matched to a `version :latest` cask, with a newer release in
    /// its own Sparkle feed.
    private func status(caskroom: Set<String>) async throws -> AppReleaseStatus {
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let http = StubAppReleaseHTTP { url, _ in
            let body = url == HomebrewCaskIndex.indexURL ? Self.casks : Self.appcast
            return AppReleaseHTTPResponse(statusCode: 200, data: Data(body.utf8))
        }
        let sparkle = SparkleAppcastSource(http: http)
        let service = AppReleaseCheckService(
            catalog: AppReleaseCatalogSource(catalog: AppReleaseCatalog(entries: []), http: http, sparkle: sparkle),
            homebrew: HomebrewCaskSource(index: HomebrewCaskIndex(http: http, cacheDirectory: cacheDirectory), hostIsArm64: true),
            sources: [sparkle],
            installedCaskTokens: { caskroom }
        )
        let app = InstalledApp(
            bundleID: "com.example.Latest",
            name: "Latest",
            url: URL(fileURLWithPath: "/Applications/Latest.app"),
            shortVersion: "2.0",
            teamID: "TEAM123456",
            sparkleFeedURL: URL(string: "https://example.com/appcast.xml")
        )
        let rows = await service.check([app], preferences: AppReleasePreferences())
        return try #require(rows.first).status
    }

    @Test("a brew-installed app is brew-managed even when its cask has no usable version")
    func brewManagedWithoutCaskVersion() async throws {
        guard case .available(let candidate, let strategy) = try await status(caskroom: ["latest-app"]) else {
            Issue.record("expected an available update")
            return
        }
        #expect(candidate.source == .sparkle)
        #expect(strategy == .linkOnly(URL(string: "https://example.com/news"), reason: .brewCaskBehind))
    }

    @Test("a matched cask that brew didn't install leaves the app to the in-place path")
    func matchedCaskNotInstalled() async throws {
        guard case .available(_, let strategy) = try await status(caskroom: ["other"]) else {
            Issue.record("expected an available update")
            return
        }
        #expect(strategy == .inPlace)
    }
}
