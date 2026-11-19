import Foundation
import Testing
@testable import GargantuaCore

@Suite("DefaultAppReleaseInventory")
struct AppReleaseInventoryTests {
    private struct StubEnumerator: AppBundleEnumerating {
        let urls: [URL]
        func enumerateBundles() -> [URL] { urls }
    }

    private static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gargantua-inv-\(UUID().uuidString)")
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
            "KSProductID": "com.google.Chrome",
        ], mas: true)
        let bar = try makeApp(in: root, "Bar", plist: [
            "CFBundleIdentifier": "com.test.bar", "SUFeedURL": "http://x.test/feed.xml",
        ])
        let noID = try makeApp(in: root, "NoID", plist: ["CFBundleName": "x"])

        let apps = await DefaultAppReleaseInventory(
            enumerator: StubEnumerator(urls: [foo, bar, noID, foo]),
            teamIDReader: { _ in "TEAM123456" },
            excludedBundleIDs: [], isUpdatableLocation: { _ in true },
            googleUpdaterInstalled: { true }, isOwnedByRoot: { _ in true }
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
        #expect(fooApp.selfUpdater == AppReleaseSelfUpdater(productID: "com.google.Chrome"))
        let barApp = try #require(apps.first { $0.bundleID == "com.test.bar" })
        #expect(barApp.selfUpdater == nil)
        #expect(barApp.sparkleFeedURL == nil)
        #expect(barApp.name == "Bar")
        #expect(!barApp.isMAS)
    }

    @Test("Google's updater keeps an app current only for a Google product root owns, with the updater installed")
    func googleSelfUpdater() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = try makeApp(in: root, "Chrome", plist: ["CFBundleIdentifier": "com.google.Chrome", "KSProductID": "com.google.Chrome"])
        let brave = try makeApp(in: root, "Brave", plist: ["CFBundleIdentifier": "com.brave.Browser", "KSProductID": "com.brave.Browser"])
        func updaters(daemon: Bool, rootOwned: Bool) async -> [String: AppReleaseSelfUpdater?] {
            let apps = await DefaultAppReleaseInventory(
                enumerator: StubEnumerator(urls: [chrome, brave]), teamIDReader: { _ in nil },
                excludedBundleIDs: [], isUpdatableLocation: { _ in true },
                googleUpdaterInstalled: { daemon }, isOwnedByRoot: { _ in rootOwned }
            ).installedApps()
            return Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleID, $0.selfUpdater) })
        }
        let kept = await updaters(daemon: true, rootOwned: true)
        #expect(kept["com.google.Chrome"] == AppReleaseSelfUpdater(productID: "com.google.Chrome"))
        #expect(kept["com.brave.Browser"] == .some(nil))
        #expect(await updaters(daemon: false, rootOwned: true)["com.google.Chrome"] == .some(nil))
        #expect(await updaters(daemon: true, rootOwned: false)["com.google.Chrome"] == .some(nil))
        // This test's own bundle isn't root's.
        #expect(!DefaultAppReleaseInventory.isOwnedByRoot(chrome))
    }

    @Test("one bundle is re-read on its own, with the same exclusions as a full scan")
    func installedAppAtURL() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let foo = try makeApp(in: root, "Foo", plist: ["CFBundleIdentifier": "com.test.foo", "CFBundleShortVersionString": "3.1"])
        let skipped = try makeApp(in: root, "Skip", plist: ["CFBundleIdentifier": "com.test.skip"])
        let inventory = DefaultAppReleaseInventory(
            enumerator: StubEnumerator(urls: []), teamIDReader: { _ in "TEAM123456" }, excludedBundleIDs: ["com.test.skip"], isUpdatableLocation: { _ in true }
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
            enumerator: StubEnumerator(urls: [foo]), teamIDReader: { _ in "TEAM123456" }, excludedBundleIDs: ["com.test.foo"], isUpdatableLocation: { _ in true }
        ).installedApps()
        #expect(apps.isEmpty)
    }

    @Test("update-location filter", arguments: [
        ("/Applications/Foo.app", true, "/Users/test"),
        ("/Applications/Utilities/Foo.app", true, "/Users/test"),
        ("/Users/test/Applications/Foo.app", true, "/Users/test"),
        ("/Users/test/Downloads/Foo.app", true, "/Users/test"),
        ("/System/Applications/Notes.app", true, "/Users/test"),
        ("/Applications/Foo.app/Contents/Helpers/Helper.app", false, "/Users/test"),
        ("/Users/test/.codex/computer-use/Codex Computer Use.app", false, "/Users/test"),
        ("/Users/test/Library/Application Support/X/Updater.app", false, "/Users/test"),
        ("/Library/Application Support/X/Y.app", false, "/Users/test"),
        ("/System/Library/CoreServices/Z.app", false, "/Users/test"),
        ("/private/var/folders/ab/T/AppTranslocation/UUID/d/Foo.app", false, "/Users/test"),
        ("/Volumes/Foo/Foo.app", false, "/Users/test"),
        ("/opt/homebrew/Caskroom/x/1.0/X.app", false, "/Users/test"),
        ("/Applications/Setapp/Foo.app", true, "/Users/test"),
        ("/tmp/Foo.app", false, "/Users/test"),
        ("/var/x/Foo.app", false, "/Users/test"),
        ("/home/u/Applications/Foo.app", true, "/home/u"),
        ("/home/u/Library/X.app", false, "/home/u"),
        ("/Users/.foo/Applications/A.app", true, "/Users/.foo"),
    ] as [(String, Bool, String)]) // swiftlint:disable:this large_tuple
    func updatableLocation(path: String, expected: Bool, home: String) {
        #expect(DefaultAppReleaseInventory.isUpdatableLocation(
            URL(fileURLWithPath: path), home: URL(fileURLWithPath: home)
        ) == expected)
    }

    @Test func installedAppsSkipsHelperAndToolPrivateBundles() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plist: (String) -> [String: Any] = { ["CFBundleIdentifier": $0] }
        let normal = try makeApp(in: root, "Normal", plist: plist("com.test.normal"))
        let nested = try makeApp(in: normal.appendingPathComponent("Contents/Helpers"), "Helper", plist: plist("com.test.helper"))
        let hidden = try makeApp(in: root.appendingPathComponent(".tool"), "Hidden", plist: plist("com.test.hidden"))

        // The real rule, with the temp root standing in for /Applications.
        let rootPath = root.standardizedFileURL.path
        let apps = await DefaultAppReleaseInventory(
            enumerator: StubEnumerator(urls: [normal, nested, hidden]),
            teamIDReader: { _ in "TEAM123456" },
            excludedBundleIDs: [],
            isUpdatableLocation: { url in
                DefaultAppReleaseInventory.isUpdatableLocation(
                    URL(fileURLWithPath: "/Applications" + url.standardizedFileURL.path.dropFirst(rootPath.count))
                )
            }
        ).installedApps()
        #expect(apps.map(\.bundleID) == ["com.test.normal"])
    }
}
