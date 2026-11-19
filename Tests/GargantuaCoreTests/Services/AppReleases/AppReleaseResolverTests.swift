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

    @Test("the app's own feed caps the version other sources may offer")
    func vendorFeedCeiling() {
        let feedCurrent = candidate(.sparkle, "1.0")
        let caskMajor = candidate(.homebrewCask, "2.0")
        #expect(resolve(app(), [.sparkle: .found(feedCurrent), .homebrewCask: .found(caskMajor)])
            == .upToDate(latest: feedCurrent))
        #expect(resolve(app(), [.sparkle: .noEligibleRelease, .homebrewCask: .found(caskMajor)]) == .upToDate(latest: nil))
        // A failed feed sets no ceiling, and brew-managed apps follow the cask.
        #expect(resolve(app(), [.sparkle: .failed("offline"), .homebrewCask: .found(caskMajor)])
            == .available(caskMajor, .inPlace))
        let brewCask = candidate(.homebrewCask, "2.0", token: "example")
        #expect(resolve(app(), [.sparkle: .found(feedCurrent), .homebrewCask: .found(brewCask)], brewToken: "example")
            == .available(brewCask, .brewUpgrade(token: "example")))
    }

    @Test("a row names only the source of what it offers")
    func rowNamesOfferedSource() {
        func sources(
            _ app: InstalledApp,
            _ outcomes: [AppReleaseSourceKind: AppReleaseSourceOutcome],
            brewToken: String? = nil,
            preferences: AppReleasePreferences = AppReleasePreferences()
        ) -> [AppReleaseSourceKind] {
            AppReleaseResolver.resolve(
                app: app, outcomes: outcomes, brewManagedToken: brewToken, preferences: preferences, osVersion: os
            ).sources
        }
        let cask = candidate(.homebrewCask, "1.1", token: "example")
        let store = AppReleaseSourceOutcome.found(candidate(.appStore, "3.0", download: nil))
        #expect(sources(app(isMAS: true), [.appStore: store, .homebrewCask: .found(cask)]) == [.appStore])
        #expect(sources(app(), [.sparkle: .found(candidate(.sparkle, "1.2")), .homebrewCask: .found(cask)]) == [.sparkle])
        // Sparkle wins the tie, but the row offers the cask brew will install.
        let tied = [AppReleaseSourceKind.sparkle: AppReleaseSourceOutcome.found(candidate(.sparkle, "1.1")), .homebrewCask: .found(cask)]
        #expect(sources(app(), tied, brewToken: "example") == [.homebrewCask])
        #expect(sources(app("1.2"), [.sparkle: .found(candidate(.sparkle, "1.2"))]) == [.sparkle])
        #expect(sources(app(), [.sparkle: .failed("x"), .homebrewCask: .failed("y")]) == [.sparkle, .homebrewCask])

        var skipping = AppReleasePreferences()
        skipping.skippedVersions["com.example.App"] = "1.2"
        let skipped = [AppReleaseSourceKind.sparkle: AppReleaseSourceOutcome.found(candidate(.sparkle, "1.2")), .homebrewCask: .found(cask)]
        #expect(sources(app(), skipped, preferences: skipping) == [.sparkle])
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

    @Test("a release newer only by build is not one the cask has, so brew-managed links only")
    func brewCaskWithoutChosenBuild() {
        let installed = InstalledApp(
            bundleID: "com.example.App",
            name: "Example",
            url: URL(fileURLWithPath: "/Applications/Example.app"),
            shortVersion: "1.0",
            buildVersion: "100",
            teamID: "ABCDE12345"
        )
        let sparkle = AppReleaseCandidate(
            source: .sparkle,
            version: AppReleaseVersion(short: "1.0", build: "101"),
            downloadURL: URL(string: "https://example.com/Example.zip"),
            vendorURL: URL(string: "https://example.com")
        )
        let cask = candidate(.homebrewCask, "1.0", token: "example")

        let status = resolve(installed, [.sparkle: .found(sparkle), .homebrewCask: .found(cask)], brewToken: "example")

        #expect(status == .available(sparkle, .linkOnly(URL(string: "https://example.com"), reason: .brewCaskBehind)))
    }

    @Test("brew upgrade is offered only when the index's cask is the installed one")
    func brewUpgradeNeedsOwningCask() {
        let cask = candidate(.homebrewCask, "2.0", token: "example")
        #expect(resolve(app(), [.homebrewCask: .found(cask)], brewToken: "example@beta")
            == .available(cask, .linkOnly(URL(string: "https://example.com"), reason: .brewCaskBehind)))
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

    @Test("a skip names the release the row offers, however a source words it")
    func skipMatchesOfferedRelease() {
        func sparkle(build: String) -> AppReleaseCandidate {
            AppReleaseCandidate(
                source: .sparkle,
                version: AppReleaseVersion(short: "2.4.1", build: build),
                downloadURL: URL(string: "https://example.com/Example.zip")
            )
        }
        let cask = candidate(.homebrewCask, "2.4.1", token: "example")
        let id = "com.example.App"

        // The brew row offered the cask's "2.4.1", though the tie-break picks Sparkle's "2.4.1 (812)".
        let both: [AppReleaseSourceKind: AppReleaseSourceOutcome] = [.sparkle: .found(sparkle(build: "812")), .homebrewCask: .found(cask)]
        let asCask = AppReleasePreferences(skippedVersions: [id: "2.4.1"])
        #expect(resolve(app(), both, brewToken: "example", preferences: asCask) == .skippedVersion("2.4.1"))

        // Skipped as Sparkle worded it; the feed then fails and Homebrew is the only source.
        let asSparkle = AppReleasePreferences(skippedVersions: [id: "2.4.1 (812)"])
        #expect(resolve(app(), [.homebrewCask: .found(cask)], preferences: asSparkle) == .skippedVersion("2.4.1 (812)"))

        // A later build of the skipped version is another release.
        let later = resolve(app(), [.sparkle: .found(sparkle(build: "813"))], preferences: asSparkle)
        #expect(later == .available(sparkle(build: "813"), .inPlace))
    }

    @Test("a release found installed under another version string is not offered again")
    func confirmedReleaseIsCurrent() {
        // The cask says 2026.2.2.9; the bundle it ships says 2026.2.
        let cask = candidate(.homebrewCask, "2026.2.2.9", token: "example")
        let outcomes: [AppReleaseSourceKind: AppReleaseSourceOutcome] = [.homebrewCask: .found(cask)]
        let confirmed = AppReleasePreferences(confirmedReleases: [
            "com.example.App": AppReleaseConfirmedRelease(offered: "2026.2.2.9", installed: "2026.2", source: .homebrewCask),
        ])

        #expect(resolve(app("2026.2"), outcomes) == .available(cask, .inPlace))
        #expect(resolve(app("2026.2"), outcomes, preferences: confirmed) == .upToDate(latest: cask))
        // Only for the bundle version that download held, and only that release.
        #expect(resolve(app("2026.1"), outcomes, preferences: confirmed) == .available(cask, .inPlace))
        let next = candidate(.homebrewCask, "2026.2.3.1", token: "example")
        #expect(resolve(app("2026.2"), [.homebrewCask: .found(next)], preferences: confirmed) == .available(next, .inPlace))

        // What Homebrew's download held says nothing about another source's release of that number.
        let feed = candidate(.sparkle, "2026.2.2.9")
        #expect(resolve(app("2026.2"), [.sparkle: .found(feed)], preferences: confirmed) == .available(feed, .inPlace))

        // Brew-managed: another source's update doesn't bring the confirmed cask back as a brew upgrade.
        let older = candidate(.sparkle, "2026.2.1")
        let both: [AppReleaseSourceKind: AppReleaseSourceOutcome] = [.sparkle: .found(older), .homebrewCask: .found(cask)]
        let managed = resolve(app("2026.2"), both, brewToken: "example", preferences: confirmed)
        #expect(managed == .available(older, .linkOnly(older.vendorURL ?? older.releaseNotesURL, reason: .brewCaskBehind)))
    }
}
