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

    /// Under home: the system temp dir is /private/var, which the updater skips.
    private static func tempRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("gargantua-inv-\(UUID().uuidString)")
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
        let root = Self.tempRoot()
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

    @Test("one bundle is re-read on its own, with the same exclusions as a full scan")
    func installedAppAtURL() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let foo = try makeApp(in: root, "Foo", plist: ["CFBundleIdentifier": "com.test.foo", "CFBundleShortVersionString": "3.1"])
        let skipped = try makeApp(in: root, "Skip", plist: ["CFBundleIdentifier": "com.test.skip"])
        let inventory = DefaultAppReleaseInventory(
            enumerator: StubEnumerator(urls: []), signatureReader: StubSigner(), excludedBundleIDs: ["com.test.skip"]
        )

        #expect(await inventory.installedApp(at: foo)?.shortVersion == "3.1")
        #expect(await inventory.installedApp(at: skipped) == nil)
        #expect(await inventory.installedApp(at: root.appendingPathComponent("Gone.app")) == nil)
    }

    @Test func excludedBundleIDsAreDropped() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let foo = try makeApp(in: root, "Foo", plist: ["CFBundleIdentifier": "com.test.foo"])
        let apps = await DefaultAppReleaseInventory(
            enumerator: StubEnumerator(urls: [foo]), signatureReader: StubSigner(), excludedBundleIDs: ["com.test.foo"]
        ).installedApps()
        #expect(apps.isEmpty)
    }

    @Test("update-location filter", arguments: [
        ("/Applications/Foo.app", true),
        ("/Applications/Utilities/Foo.app", true),
        ("/Users/test/Applications/Foo.app", true),
        ("/Users/test/Downloads/Foo.app", true),
        ("/System/Applications/Notes.app", true),
        ("/Applications/Foo.app/Contents/Helpers/Helper.app", false),
        ("/Users/test/.codex/computer-use/Codex Computer Use.app", false),
        ("/Users/test/Library/Application Support/X/Updater.app", false),
        ("/Library/Application Support/X/Y.app", false),
        ("/System/Library/CoreServices/Z.app", false),
        ("/private/var/folders/ab/T/AppTranslocation/UUID/d/Foo.app", false),
        ("/Volumes/Foo/Foo.app", false),
        ("/opt/homebrew/Caskroom/x/1.0/X.app", false),
    ])
    func updatableLocation(path: String, expected: Bool) {
        #expect(DefaultAppReleaseInventory.isUpdatableLocation(
            URL(fileURLWithPath: path), home: URL(fileURLWithPath: "/Users/test")
        ) == expected)
    }

    @Test func installedAppsSkipsHelperAndToolPrivateBundles() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist: (String) -> [String: Any] = { ["CFBundleIdentifier": $0] }
        let normal = try makeApp(in: root, "Normal", plist: plist("com.test.normal"))
        let nested = try makeApp(in: normal.appendingPathComponent("Contents/Helpers"), "Helper", plist: plist("com.test.helper"))
        let hidden = try makeApp(in: root.appendingPathComponent(".tool"), "Hidden", plist: plist("com.test.hidden"))
        let library = try makeApp(in: home.appendingPathComponent("Library/gargantua-test-\(UUID().uuidString)"), "Lib", plist: plist("com.test.lib"))
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent()) }

        let apps = await DefaultAppReleaseInventory(
            enumerator: StubEnumerator(urls: [normal, nested, hidden, library]), signatureReader: StubSigner(), excludedBundleIDs: []
        ).installedApps()
        #expect(apps.map(\.bundleID) == ["com.test.normal"])
    }
}
