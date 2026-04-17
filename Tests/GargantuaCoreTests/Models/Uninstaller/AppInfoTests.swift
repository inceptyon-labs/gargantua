import Foundation
import Testing
@testable import GargantuaCore

@Suite("AppInfo")
struct AppInfoTests {

    static let sample = AppInfo(
        bundleID: "com.google.Chrome",
        name: "Google Chrome",
        displayName: "Google Chrome",
        shortVersion: "120.0.6099.71",
        bundleVersion: "6099.71",
        bundlePath: "/Applications/Google Chrome.app",
        executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        installDate: Date(timeIntervalSince1970: 1_700_000_000),
        lastUsedDate: Date(timeIntervalSince1970: 1_705_000_000),
        isRunning: false,
        isSystemApp: false,
        sizeOnDisk: 512_000_000,
        teamIdentifier: "EQHXZ8M8AV",
        signatureValid: true
    )

    @Test("id is derived from bundleID")
    func idMatchesBundleID() {
        #expect(Self.sample.id == "com.google.Chrome")
        #expect(Self.sample.id == Self.sample.bundleID)
    }

    @Test("All populated fields are preserved")
    func fieldsPopulated() {
        let app = Self.sample
        #expect(app.name == "Google Chrome")
        #expect(app.displayName == "Google Chrome")
        #expect(app.shortVersion == "120.0.6099.71")
        #expect(app.bundleVersion == "6099.71")
        #expect(app.bundlePath == "/Applications/Google Chrome.app")
        #expect(app.executablePath?.hasSuffix("MacOS/Google Chrome") == true)
        #expect(app.isRunning == false)
        #expect(app.isSystemApp == false)
        #expect(app.sizeOnDisk == 512_000_000)
        #expect(app.teamIdentifier == "EQHXZ8M8AV")
        #expect(app.signatureValid == true)
    }

    @Test("Defaults leave optional metadata unset")
    func defaults() {
        let app = AppInfo(
            bundleID: "com.example.Minimal",
            name: "Minimal",
            bundlePath: "/Applications/Minimal.app"
        )
        #expect(app.displayName == nil)
        #expect(app.shortVersion == nil)
        #expect(app.bundleVersion == nil)
        #expect(app.executablePath == nil)
        #expect(app.installDate == nil)
        #expect(app.lastUsedDate == nil)
        #expect(app.isRunning == false)
        #expect(app.isSystemApp == false)
        #expect(app.sizeOnDisk == nil)
        #expect(app.teamIdentifier == nil)
        #expect(app.signatureValid == nil)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Self.sample)
        let decoded = try JSONDecoder().decode(AppInfo.self, from: data)
        #expect(decoded == Self.sample)
    }

    @Test("Equatable distinguishes differing bundle identifiers")
    func equatableByBundleID() {
        let a = AppInfo(bundleID: "com.a", name: "A", bundlePath: "/A.app")
        let b = AppInfo(bundleID: "com.b", name: "A", bundlePath: "/A.app")
        #expect(a != b)
    }
}
