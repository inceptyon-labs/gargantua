import Foundation
import Testing
@testable import GargantuaCore

@Suite("RemnantScanner template expansion")
struct RemnantScannerTemplateTests {

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
}
