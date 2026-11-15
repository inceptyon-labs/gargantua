import Foundation
import os
import Testing
@testable import GargantuaCore

@Suite("AppReleaseAnnouncement")
struct AppReleaseAnnouncementTests {
    final class RecordingNotifier: AppReleaseUpdateNotifying {
        private let state: OSAllocatedUnfairLock<(calls: Int, result: Bool)>
        init(result: Bool = true) { state = OSAllocatedUnfairLock(initialState: (0, result)) }
        var calls: Int { state.withLock { $0.calls } }
        func setResult(_ value: Bool) { state.withLock { $0.result = value } }
        func deliver(count _: Int, appNames _: [String]) async -> Bool {
            state.withLock { $0.calls += 1; return $0.result }
        }
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "announce-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test("pending round-trips")
    func roundTrip() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppReleaseAnnouncement.pending(in: defaults) == nil)
        let item = AppReleaseAnnouncement(count: 2, appNames: ["A", "B"])
        item.storePending(in: defaults)
        #expect(AppReleaseAnnouncement.pending(in: defaults) == item)
    }

    @Test("posts once and records the posted ID")
    func postsOnce() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = AppReleaseAnnouncement(count: 1, appNames: ["A"])
        item.storePending(in: defaults)
        let notifier = RecordingNotifier()
        #expect(await AppReleaseAnnouncementPoster.postPending(defaults: defaults, notifier: notifier))
        #expect(await !AppReleaseAnnouncementPoster.postPending(defaults: defaults, notifier: notifier))
        #expect(notifier.calls == 1)
        #expect(defaults.string(forKey: AppReleaseAnnouncement.postedKey) == item.id.uuidString)
    }

    @Test("a failed delivery isn't recorded and is retried")
    func retries() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        AppReleaseAnnouncement(count: 1, appNames: ["A"]).storePending(in: defaults)
        let notifier = RecordingNotifier(result: false)
        #expect(await !AppReleaseAnnouncementPoster.postPending(defaults: defaults, notifier: notifier))
        #expect(defaults.string(forKey: AppReleaseAnnouncement.postedKey) == nil)
        notifier.setResult(true)
        #expect(await AppReleaseAnnouncementPoster.postPending(defaults: defaults, notifier: notifier))
        #expect(notifier.calls == 2)
    }

    @Test("skips stale and future-dated announcements, and nothing pending")
    func skips() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let notifier = RecordingNotifier()
        #expect(await !AppReleaseAnnouncementPoster.postPending(defaults: defaults, notifier: notifier))
        let now = Date()
        AppReleaseAnnouncement(count: 1, appNames: [], created: now.addingTimeInterval(-25 * 3600)).storePending(in: defaults)
        #expect(await !AppReleaseAnnouncementPoster.postPending(defaults: defaults, notifier: notifier, now: now))
        AppReleaseAnnouncement(count: 1, appNames: [], created: now.addingTimeInterval(60)).storePending(in: defaults)
        #expect(await !AppReleaseAnnouncementPoster.postPending(defaults: defaults, notifier: notifier, now: now))
        #expect(notifier.calls == 0)
    }

    @Test("link actions")
    func links() {
        #expect(AppReleaseLink.action(for: AppReleaseLink.openURL) == .open)
        #expect(AppReleaseLink.action(for: AppReleaseLink.announceURL) == .announce)
        #expect(AppReleaseLink.action(for: URL(string: "gargantua://activate?key=x")!) == nil)
        #expect(AppReleaseLink.action(for: URL(string: "https://app-updates")!) == nil)
    }

    @Test("ContainingAppUpdateNotifier stores the announcement and opens the announce link")
    func containingNotifier() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = URL(fileURLWithPath: "/Applications/Foo.app")
        for result in [true, false] {
            let ids = OSAllocatedUnfairLock(initialState: "")
            let opened = OSAllocatedUnfairLock<[(URL, URL)]>(initialState: [])
            let notifier = ContainingAppUpdateNotifier(suiteName: suite, appURL: app, appBundleID: "com.example.foo") { app, link, id in
                opened.withLock { $0.append((app, link)); ids.withLock { $0 = id } }
                return result
            }
            #expect(await notifier.deliver(count: 2, appNames: ["A", "B"]) == result)
            let stored = AppReleaseAnnouncement.pending(in: defaults)
            #expect(stored?.count == 2)
            #expect(stored?.appNames == ["A", "B"])
            #expect(opened.withLock { $0.count } == 1)
            #expect(ids.withLock { $0 } == "com.example.foo")
            #expect(opened.withLock { $0[0].0 == app && $0[0].1 == AppReleaseLink.announceURL })
        }
    }

    @Test("containingAppURL finds the enclosing app, nil outside")
    func containingURL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ann-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Foo.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.foo"], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let inside = contents.appendingPathComponent("MacOS/Helper")
        #expect(AppReleaseBackgroundCheck.containingAppURL(executable: inside)?.lastPathComponent == "Foo.app")
        #expect(AppReleaseBackgroundCheck.containingAppURL(executable: root.appendingPathComponent("tool")) == nil)
    }

    @Test("a launch is hidden only when the app isn't already running")
    func hideDecision() {
        #expect(ContainingAppUpdateNotifier.shouldHide(runningCount: 0))
        #expect(!ContainingAppUpdateNotifier.shouldHide(runningCount: 1))
    }

    @Test("containingAppURL is nil for the host's own bundle ID, a missing plist and a malformed plist")
    func containingURLRejects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ann-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, plist: Data?) throws -> URL {
            let contents = root.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            if let plist { try plist.write(to: contents.appendingPathComponent("Info.plist")) }
            return contents.appendingPathComponent("MacOS/Helper")
        }
        if let ownID = Bundle.main.bundleIdentifier {
            let own = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": ownID], format: .xml, options: 0)
            #expect(AppReleaseBackgroundCheck.containingAppURL(executable: try app("Own", plist: own)) == nil)
        }
        #expect(AppReleaseBackgroundCheck.containingAppURL(executable: try app("Missing", plist: nil)) == nil)
        #expect(AppReleaseBackgroundCheck.containingAppURL(executable: try app("Bad", plist: Data("junk".utf8))) == nil)
    }
}
