import Foundation
import Testing
@testable import GargantuaCore

@Suite("AppReleaseVersion")
struct AppReleaseVersionTests {
    private func version(_ short: String?, _ build: String? = nil) -> AppReleaseVersion {
        AppReleaseVersion(short: short, build: build)
    }

    @Test("higher marketing version is newer; equal padded versions are not")
    func marketingVersionOrder() {
        #expect(version("2.1").isNewer(than: version("2.0.9")))
        #expect(version("10.0").isNewer(than: version("9.9.9")))
        #expect(!version("1.2").isNewer(than: version("1.2.0")))
        #expect(!version("1.2.0").isNewer(than: version("1.2")))
        #expect(!version("1.9").isNewer(than: version("2.0")))
    }

    @Test("prerelease sorts below its release, and digit-run compare does not inflate it")
    func prereleaseOrder() {
        #expect(!version("2.0-beta1").isNewer(than: version("2.0.0")))
        #expect(version("2.0.0").isNewer(than: version("2.0-beta1")))
        #expect(!version("1.0.0-rc.2").isNewer(than: version("1.0.0")))
        #expect(version("2.0b3").isPrerelease)
        #expect(version("2.0rc1").isNewer(than: version("2.0beta4")))
    }

    @Test("non-prerelease suffixes are not treated as prereleases")
    func nonPrereleaseSuffixes() {
        #expect(!version("2.0 (1234)").isPrerelease)
        #expect(!version("1.5 build 7").isPrerelease)
        #expect(!version("3.1-universal").isPrerelease)
        #expect(!version("1.0-arm64").isPrerelease)
        #expect(version("v1.3").isNewer(than: version("1.2")))
    }

    @Test("build number breaks a tie on equal marketing versions")
    func buildTieBreak() {
        #expect(version("2.4", "812").isNewer(than: version("2.4", "800")))
        #expect(!version("2.4", "800").isNewer(than: version("2.4", "812")))
        #expect(!version("2.4", "999").isNewer(than: version("2.5", "100")))
    }

    @Test("build-only feed compares against the installed build, never the marketing version")
    func buildOnlyComparison() {
        #expect(version(nil, "1500").isNewer(than: version("3.0", "1400")))
        #expect(!version(nil, "1500").isNewer(than: version("3.0", nil)))
    }

    @Test("uncomparable versions read as not newer")
    func uncomparable() {
        #expect(!version("latest").isNewer(than: version("1.0")))
        #expect(!version(nil, nil).isNewer(than: version("1.0")))
        #expect(!version("2.0").isNewer(than: version(nil, nil)))
    }

    @Test("cask version splits short and build on the first comma")
    func caskVersion() {
        let parsed = AppReleaseVersion.cask("1.2.3,456")
        #expect(parsed?.short == "1.2.3")
        #expect(parsed?.build == "456")
        #expect(AppReleaseVersion.cask("5.0,abc,def")?.build == "abc")
        #expect(AppReleaseVersion.cask("2.0:1.9")?.short == "2.0")
        #expect(AppReleaseVersion.cask("latest") == nil)
        #expect(AppReleaseVersion.cask("") == nil)
        #expect(AppReleaseVersion.cask("1.2.3")?.build == nil)
    }
}
