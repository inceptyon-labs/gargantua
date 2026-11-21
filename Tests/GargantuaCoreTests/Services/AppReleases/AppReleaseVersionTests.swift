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

    @Test("builds that aren't plain numbers or one vendor's prefixed numbers never decide the order")
    func nonNumericBuilds() {
        #expect(!version("5.11492.5", "1403e2cf44abfb23809c8ae11238d5e9704a41c2").isNewer(than: version("5.11492.5", "5.11492.5")))
        // Different products, a tail that isn't a dotted number, or a prefix that isn't letters.
        #expect(!version("2025.3", "IU-253.40000").isNewer(than: version("2025.3", "AI-253.32098")))
        #expect(!version("2025.3", "AI-253.40000x").isNewer(than: version("2025.3", "AI-253.32098")))
        #expect(!version("2025.3", "7-253.40000").isNewer(than: version("2025.3", "7-253.32098")))
    }

    @Test("builds sharing a vendor prefix compare by their dotted numbers, as Android Studio's do")
    func vendorPrefixedBuilds() {
        let installed = "AI-262.10968.63.2622.16840690"
        let patched = "AI-262.10968.63.2622.16975389"
        #expect(version("2026.2", patched).isNewer(than: version("2026.2", installed)))
        #expect(!version("2026.2", installed).isNewer(than: version("2026.2", patched)))
        #expect(!version("2026.2", installed).isNewer(than: version("2026.2", installed)))
        #expect(version("2025.3", "AI-253.40000").isNewer(than: version("2025.3", "AI-253.32098")))
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

    @Test("a single trailing letter is a patch release, newer than the bare version")
    func patchLetter() {
        #expect(version("2.3.1a").isNewer(than: version("2.3.1")))
        #expect(!version("2.3.1").isNewer(than: version("2.3.1a")))
        #expect(version("2.3.1b").isNewer(than: version("2.3.1a")))
        #expect(version("2.3.2").isNewer(than: version("2.3.1a")))
        #expect(!version("2.3.1a").isPrerelease)
        #expect(version("2.0a1").isPrerelease)
    }

    @Test("a dotted version with the build written into it names the installed release")
    func foldedBuild() {
        #expect(version("3.5.2", "1").isFolded(into: "3.5.2.1"))
        #expect(version("3.5.2", "3.5.2.1").isFolded(into: "3.5.2.1"))
        #expect(!version("3.5.2", "1").isFolded(into: "3.5.2.2"))
        #expect(!version("3.5.2", "1").isFolded(into: "3.5.3"))
        #expect(!version("3.5.2", "abc").isFolded(into: "3.5.2.1"))
        // An ordinary first patch release of a two-part version.
        #expect(!version("1.2", "1").isFolded(into: "1.2.1"))
    }
}
