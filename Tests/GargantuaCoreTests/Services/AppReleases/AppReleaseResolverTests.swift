import Foundation
import Testing
@testable import GargantuaCore

@Suite("AppReleaseResolver")
struct AppReleaseResolverTests {
    private let os = OperatingSystemVersion(majorVersion: 15, minorVersion: 2, patchVersion: 0)

    private func app(
        _ version: String = "1.0",
        teamID: String? = "ABCDE12345",
        isMAS: Bool = false,
        rootOwned: Bool = false
    ) -> InstalledApp {
        InstalledApp(
            bundleID: "com.example.App",
            name: "Example",
            url: URL(fileURLWithPath: "/Applications/Example.app"),
            shortVersion: version,
            teamID: teamID,
            isMAS: isMAS,
            isRootOwned: rootOwned
        )
    }

    private func candidate(
        _ source: AppReleaseSourceKind,
        _ version: String,
        download: String? = "https://example.com/Example.zip",
        minOS: String? = nil,
        token: String? = nil,
        linkOnly: Bool = false
    ) -> AppReleaseCandidate {
        AppReleaseCandidate(
            source: source,
            version: AppReleaseVersion(short: version, build: nil),
            downloadURL: download.flatMap(URL.init(string:)),
            minimumSystemVersion: minOS,
            vendorURL: URL(string: "https://example.com"),
            caskToken: token,
            allowsInPlaceInstall: !linkOnly
        )
    }

    private func resolve(
        _ app: InstalledApp,
        _ outcomes: [AppReleaseSourceKind: AppReleaseSourceOutcome],
        brewToken: String? = nil,
        preferences: AppReleasePreferences = AppReleasePreferences()
    ) -> AppReleaseStatus {
        AppReleaseResolver.resolve(
            app: app, outcomes: outcomes, brewManagedToken: brewToken, preferences: preferences, osVersion: os
        ).status
    }

    @Test("newest version across sources wins and installs in place")
    func newestWins() {
        let status = resolve(app(), [
            .sparkle: .found(candidate(.sparkle, "1.2")),
            .homebrewCask: .found(candidate(.homebrewCask, "1.1")),
        ])
        #expect(status == .available(candidate(.sparkle, "1.2"), .inPlace))
    }

    @Test("on a version tie an installable release beats a link-only one, then catalog beats Sparkle")
    func tieBreak() {
        let linkOnlySparkle = candidate(.sparkle, "2.0", download: nil)
        let cask = candidate(.homebrewCask, "2.0")
        #expect(resolve(app(), [.sparkle: .found(linkOnlySparkle), .homebrewCask: .found(cask)])
            == .available(cask, .inPlace))

        let catalog = candidate(.catalog, "2.0")
        #expect(resolve(app(), [.sparkle: .found(candidate(.sparkle, "2.0")), .catalog: .found(catalog)])
            == .available(catalog, .inPlace))
    }

    @Test("App Store apps consult only the App Store and open the store page")
    func appStoreOnly() {
        let store = candidate(.appStore, "3.0", download: nil)
        let status = resolve(app(isMAS: true), [
            .appStore: .found(store),
            .homebrewCask: .found(candidate(.homebrewCask, "4.0")),
        ])
        #expect(status == .available(store, .openAppStore(URL(string: "https://example.com")!)))
    }

    @Test("brew-managed app upgrades through brew when the cask is newest, otherwise links only")
    func brewManaged() {
        let cask = candidate(.homebrewCask, "2.0", token: "example")
        #expect(resolve(app(), [.homebrewCask: .found(cask)], brewToken: "example")
            == .available(cask, .brewUpgrade(token: "example")))

        let sparkle = candidate(.sparkle, "2.1")
        let status = resolve(app(), [.homebrewCask: .found(cask), .sparkle: .found(sparkle)], brewToken: "example")
        #expect(status == .available(sparkle, .linkOnly(URL(string: "https://example.com"), reason: .brewCaskBehind)))
    }

    @Test("unsafe or unsupported installs fall back to a link with the reason")
    func linkOnlyReasons() {
        let url = URL(string: "https://example.com")
        let sparkle: [AppReleaseSourceKind: AppReleaseSourceOutcome] = [.sparkle: .found(candidate(.sparkle, "2.0"))]
        #expect(resolve(app(rootOwned: true), sparkle) == .available(candidate(.sparkle, "2.0"), .linkOnly(url, reason: .rootOwned)))
        #expect(resolve(app(teamID: nil), sparkle) == .available(candidate(.sparkle, "2.0"), .linkOnly(url, reason: .unsigned)))

        let pkg = candidate(.sparkle, "2.0", download: "https://example.com/Example.pkg")
        #expect(resolve(app(), [.sparkle: .found(pkg)]) == .available(pkg, .linkOnly(url, reason: .packageInstaller)))

        let pinnedLinkOnly = candidate(.catalog, "2.0", linkOnly: true)
        #expect(resolve(app(), [.catalog: .found(pinnedLinkOnly)])
            == .available(pinnedLinkOnly, .linkOnly(url, reason: .catalogLinkOnly)))
    }

    @Test("releases this macOS can't run, and older releases, are not offered")
    func notOffered() {
        let tooNew = candidate(.sparkle, "2.0", minOS: "26.0")
        #expect(resolve(app(), [.sparkle: .found(tooNew)]) == .upToDate(latest: nil))

        let older = candidate(.sparkle, "0.9")
        #expect(resolve(app(), [.sparkle: .found(older)]) == .upToDate(latest: older))
    }

    @Test("ignored apps and skipped versions are honored; a newer release reappears")
    func preferences() {
        let outcomes: [AppReleaseSourceKind: AppReleaseSourceOutcome] = [.sparkle: .found(candidate(.sparkle, "2.0"))]
        #expect(resolve(app(), outcomes, preferences: AppReleasePreferences(ignoredBundleIDs: ["com.example.App"])) == .ignored)

        let skipped = AppReleasePreferences(skippedVersions: ["com.example.App": "2.0"])
        #expect(resolve(app(), outcomes, preferences: skipped) == .skippedVersion("2.0"))
        #expect(resolve(app(), [.sparkle: .found(candidate(.sparkle, "2.1"))], preferences: skipped)
            == .available(candidate(.sparkle, "2.1"), .inPlace))
    }

    @Test("no source, or every source failing, reads as untracked or failed")
    func untrackedAndFailed() {
        #expect(resolve(app(), [:]) == .untracked)
        #expect(resolve(app(), [.sparkle: .failed("offline")]) == .failed("offline"))
        #expect(resolve(app(), [.sparkle: .failed("offline"), .homebrewCask: .noEligibleRelease]) == .upToDate(latest: nil))
    }

    @Test("brew-managed token requires a Caskroom install of the matched cask")
    func brewManagedToken() {
        let found = AppReleaseSourceOutcome.found(candidate(.homebrewCask, "2.0", token: "example"))
        #expect(AppReleaseCheckService.brewManagedToken(found, caskroom: ["example"]) == "example")
        #expect(AppReleaseCheckService.brewManagedToken(found, caskroom: ["other"]) == nil)
        #expect(AppReleaseCheckService.brewManagedToken(.noEligibleRelease, caskroom: ["example"]) == nil)
    }
}
