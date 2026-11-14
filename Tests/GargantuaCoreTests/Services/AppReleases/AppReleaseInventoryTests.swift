import Foundation
import Testing
@testable import GargantuaCore

@Suite("DefaultAppReleaseInventory")
struct AppReleaseInventoryTests {
    private struct StubEnumerator: AppBundleEnumerating {
        let urls: [URL]
        func enumerateBundles() -> [URL] { urls }
    }

    private struct StubSigner: CodeSignatureVerifying {
        func verify(bundleURL _: URL) -> CodeSignatureInfo { CodeSignatureInfo(valid: true, teamIdentifier: "TEAM123456") }
    }

    private func makeApp(in root: URL, _ name: String, plist: [String: Any], mas: Bool = false) throws -> URL {
        let app = root.appendingPathComponent("\(name).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if mas {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("_MASReceipt"), withIntermediateDirectories: true)
            try Data().write(to: contents.appendingPathComponent("_MASReceipt/receipt"))
        }
        return app
    }

    @Test func readsInfoPlistFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let foo = try makeApp(in: root, "Foo", plist: [
            "CFBundleIdentifier": "com.test.foo", "CFBundleName": "Foo Name",
            "CFBundleShortVersionString": "1.2", "CFBundleVersion": "34",
            "SUFeedURL": "https://x.test/feed.xml", "SUPublicEDKey": "KEY", "LSMinimumSystemVersion": "13.0",
        ], mas: true)
        let bar = try makeApp(in: root, "Bar", plist: [
            "CFBundleIdentifier": "com.test.bar", "SUFeedURL": "http://x.test/feed.xml",
        ])
        let noID = try makeApp(in: root, "NoID", plist: ["CFBundleName": "x"])

        let apps = await DefaultAppReleaseInventory(
            enumerator: StubEnumerator(urls: [foo, bar, noID, foo]),
            signatureReader: StubSigner(),
            excludedBundleIDs: []
        ).installedApps()

        #expect(apps.map(\.bundleID) == ["com.test.bar", "com.test.foo"])
        let fooApp = try #require(apps.first { $0.bundleID == "com.test.foo" })
        #expect(fooApp.name == "Foo Name")
        #expect(fooApp.shortVersion == "1.2")
        #expect(fooApp.buildVersion == "34")
        #expect(fooApp.sparkleFeedURL?.absoluteString == "https://x.test/feed.xml")
        #expect(fooApp.sparklePublicEDKey == "KEY")
        #expect(fooApp.minimumSystemVersion == "13.0")
        #expect(fooApp.isMAS)
        #expect(!fooApp.isSystem)
        #expect(!fooApp.isRootOwned)
        #expect(fooApp.teamID == "TEAM123456")
        let barApp = try #require(apps.first { $0.bundleID == "com.test.bar" })
        #expect(barApp.sparkleFeedURL == nil)
        #expect(barApp.name == "Bar")
        #expect(!barApp.isMAS)
    }

    @Test func excludedBundleIDsAreDropped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let foo = try makeApp(in: root, "Foo", plist: ["CFBundleIdentifier": "com.test.foo"])
        let apps = await DefaultAppReleaseInventory(
            enumerator: StubEnumerator(urls: [foo]), signatureReader: StubSigner(), excludedBundleIDs: ["com.test.foo"]
        ).installedApps()
        #expect(apps.isEmpty)
    }
}
