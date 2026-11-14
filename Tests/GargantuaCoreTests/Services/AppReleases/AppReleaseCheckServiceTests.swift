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
    private func status(
        caskroom: [HomebrewInstalledCask],
        indexReachable: Bool = true,
        index: String = AppReleaseCheckServiceTests.casks,
        sparkleFeed: Bool = true
    ) async throws -> AppReleaseStatus {
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let http = StubAppReleaseHTTP { url, _ in
            if url == HomebrewCaskIndex.indexURL, !indexReachable { throw AppReleaseHTTPError.network("offline") }
            let body = url == HomebrewCaskIndex.indexURL ? index : Self.appcast
            return AppReleaseHTTPResponse(statusCode: 200, data: Data(body.utf8))
        }
        let sparkle = SparkleAppcastSource(http: http)
        let service = AppReleaseCheckService(
            catalog: AppReleaseCatalogSource(catalog: AppReleaseCatalog(entries: []), http: http, sparkle: sparkle),
            homebrew: HomebrewCaskSource(index: HomebrewCaskIndex(http: http, cacheDirectory: cacheDirectory), host: HomebrewCaskHost(isArm64: true, macOSMajorVersion: 27)),
            sources: [sparkle],
            installedCasks: { caskroom }
        )
        let app = InstalledApp(
            bundleID: "com.example.Latest",
            name: "Latest",
            url: URL(fileURLWithPath: "/Applications/Latest.app"),
            shortVersion: "2.0",
            teamID: "TEAM123456",
            sparkleFeedURL: sparkleFeed ? URL(string: "https://example.com/appcast.xml") : nil
        )
        let rows = await service.check([app], preferences: AppReleasePreferences())
        return try #require(rows.first).status
    }

    @Test("a brew-installed app is brew-managed even when its cask has no usable version")
    func brewManagedWithoutCaskVersion() async throws {
        guard case .available(let candidate, let strategy) = try await status(caskroom: [HomebrewInstalledCask(token: "latest-app")]) else {
            Issue.record("expected an available update")
            return
        }
        #expect(candidate.source == .sparkle)
        #expect(strategy == .linkOnly(URL(string: "https://example.com/news"), reason: .brewCaskBehind))
    }

    @Test("a matched cask that brew didn't install leaves the app to the in-place path")
    func matchedCaskNotInstalled() async throws {
        guard case .available(_, let strategy) = try await status(caskroom: [HomebrewInstalledCask(token: "other")]) else {
            Issue.record("expected an available update")
            return
        }
        #expect(strategy == .inPlace)
    }

    @Test("a cask from a tap the index doesn't know marks the app brew-managed from the Caskroom alone")
    func caskroomOwnershipWithoutIndex() async throws {
        let prefix = try CaskroomFixture.makePrefix([
            "Caskroom/latest-tap/.metadata/INSTALL_RECEIPT.json": #"{"uninstall_artifacts":[{"app":["Latest.app"]}]}"#,
        ])
        defer { try? FileManager.default.removeItem(at: prefix) }
        let caskroom = HomebrewCaskroomProbe(prefixes: [prefix.path]).installedCasks()

        guard case .available(_, let strategy) = try await status(caskroom: caskroom, indexReachable: false) else {
            Issue.record("expected an available update")
            return
        }
        #expect(strategy == .linkOnly(URL(string: "https://example.com/news"), reason: .brewCaskBehind))
    }

    private static let publicFoo = """
    [{"token":"foo","version":"3.0","url":"https://example.com/Foo-3.0.zip","sha256":"no_check",
      "homepage":"https://example.com","artifacts":[{"app":["Latest.app"]}]}]
    """

    private func fooStatus(tap: String) async throws -> AppReleaseStatus {
        try await status(
            caskroom: [HomebrewInstalledCask(token: "foo", appNames: ["Latest.app"], tap: tap)],
            index: Self.publicFoo,
            sparkleFeed: false
        )
    }

    @Test("a cask installed from another tap doesn't take its version from the public cask of the same name")
    func thirdPartyTapIgnoresPublicCask() async throws {
        let status = try await fooStatus(tap: "acme/tap")
        if case .available(let candidate, _) = status { #expect(candidate.displayVersion != "3.0") }
    }

    @Test("a cask installed from homebrew/cask still offers the public version, brew-managed")
    func publicTapOffersPublicCask() async throws {
        guard case .available(let candidate, let strategy) = try await fooStatus(tap: "homebrew/cask") else {
            Issue.record("expected an available update")
            return
        }
        #expect(candidate.source == .homebrewCask)
        #expect(strategy != .inPlace)
    }
}
