import Foundation
import os
import Testing
@testable import GargantuaCore

@Suite("AppReleaseBackgroundCheck")
struct AppReleaseBackgroundCheckTests {
    struct StubInventory: AppReleaseInventoryProviding {
        let apps: [InstalledApp]
        var onCall: (@Sendable () -> Void)?
        func installedApps() async -> [InstalledApp] {
            onCall?()
            return apps
        }
        func installedApp(at url: URL) async -> InstalledApp? { nil }
    }

    /// Reports the given versions as available; counts calls.
    final class StubChecker: AppReleaseChecking {
        // swiftlint:disable:next nesting
        private struct State {
            var calls = 0
            var versions: [String: String]
            var failing: Set<String> = []
            var onCheck: (@Sendable () -> Void)?
        }
        private let state: OSAllocatedUnfairLock<State>
        var calls: Int { state.withLock { $0.calls } }

        init(versions: [String: String]) { state = OSAllocatedUnfairLock(initialState: State(versions: versions)) }

        func setFailing(_ ids: Set<String>) { state.withLock { $0.failing = ids } }

        func setVersion(_ id: String, _ version: String) { state.withLock { $0.versions[id] = version } }

        func clearVersion(_ id: String) { state.withLock { $0.versions[id] = nil } }

        func setOnCheck(_ action: @escaping @Sendable () -> Void) { state.withLock { $0.onCheck = action } }

        func check(_ apps: [InstalledApp], preferences: AppReleasePreferences) async -> [AppReleaseRow] {
            let (versions, failing, onCheck) = state.withLock { state in
                state.calls += 1
                return (state.versions, state.failing, state.onCheck)
            }
            onCheck?()
            return apps.map { app in
                if failing.contains(app.bundleID) { return AppReleaseRow(app: app, status: .failed("offline")) }
                if preferences.ignoredBundleIDs.contains(app.bundleID) {
                    return AppReleaseRow(app: app, status: .ignored)
                }
                guard let version = versions[app.bundleID] else {
                    return AppReleaseRow(app: app, status: .upToDate(latest: nil))
                }
                let candidate = AppReleaseCandidate(
                    source: .sparkle,
                    version: AppReleaseVersion(short: version, build: nil),
                    downloadURL: nil
                )
                return AppReleaseRow(app: app, status: .available(candidate, .linkOnly(nil, reason: .noInstallablePayload)))
            }
        }
    }

    actor RecordingNotifier: AppReleaseUpdateNotifying {
        private(set) var deliveries: [(count: Int, names: [String])] = []
        private var succeeds = true
        func setSucceeds(_ value: Bool) { succeeds = value }
        func deliver(count: Int, appNames: [String]) async -> Bool {
            deliveries.append((count, appNames))
            return succeeds
        }
    }

    final class Clock: Sendable {
        private let date: OSAllocatedUnfairLock<Date>
        init(_ date: Date) { self.date = OSAllocatedUnfairLock(initialState: date) }
        var current: Date { date.withLock { $0 } }
        func advance(hours: Double) { date.withLock { $0 = $0.addingTimeInterval(hours * 3600) } }
    }

    static func app(_ id: String, name: String) -> InstalledApp {
        InstalledApp(bundleID: id, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"), shortVersion: "1.0")
    }

    struct Harness {
        let suite = "test-\(UUID().uuidString)"
        let defaults: UserDefaults
        let checker: StubChecker
        let notifier = RecordingNotifier()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let check: AppReleaseBackgroundCheck

        init(versions: [String: String], enabled: Bool = true, onInventory: (@Sendable (String) -> Void)? = nil) {
            defaults = UserDefaults(suiteName: suite)!
            checker = StubChecker(versions: versions)
            AppReleasePreferences(ignoredBundleIDs: ["com.c"], backgroundCheckEnabled: enabled).store(in: defaults)
            let clock = clock
            let suite = suite
            var inventoryHook: (@Sendable () -> Void)?
            if let onInventory { inventoryHook = { onInventory(suite) } }
            check = AppReleaseBackgroundCheck(
                suiteName: suite,
                inventory: StubInventory(apps: [
                    AppReleaseBackgroundCheckTests.app("com.b", name: "Bravo"),
                    AppReleaseBackgroundCheckTests.app("com.a", name: "Alpha"),
                    AppReleaseBackgroundCheckTests.app("com.c", name: "Charlie"),
                ], onCall: inventoryHook),
                checker: checker,
                notifier: notifier,
                now: { clock.current }
            )
        }

        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }

    @Test("disabled preference skips the check")
    func disabled() async {
        let harness = Harness(versions: ["com.a": "2.0"], enabled: false)
        defer { harness.cleanUp() }
        #expect(await harness.check.runIfDue() == .disabled)
        #expect(harness.checker.calls == 0)
    }

    @Test("not due within the interval, due after it")
    func dueWindow() async {
        let harness = Harness(versions: [:])
        defer { harness.cleanUp() }
        AppReleaseBackgroundState(lastCheck: harness.clock.current.addingTimeInterval(-3600)).store(in: harness.defaults)
        #expect(await harness.check.runIfDue() == .notDue)
        #expect(harness.checker.calls == 0)

        AppReleaseBackgroundState(lastCheck: harness.clock.current.addingTimeInterval(-25 * 3600)).store(in: harness.defaults)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 0, notified: false))
        #expect(harness.checker.calls == 1)
    }

    @Test("first run notifies once with the non-ignored updates and stores state")
    func firstRun() async {
        let harness = Harness(versions: ["com.a": "2.0", "com.b": "3.0", "com.c": "9.0"])
        defer { harness.cleanUp() }
        #expect(await harness.check.runIfDue() == .checked(availableCount: 2, notified: true))
        let deliveries = await harness.notifier.deliveries
        #expect(deliveries.count == 1)
        #expect(deliveries.first?.count == 2)
        #expect(deliveries.first?.names == ["Alpha", "Bravo"])
        let state = AppReleaseBackgroundState.stored(in: harness.defaults)
        #expect(AppReleaseBackgroundState.storedAvailableCount(in: harness.defaults) == 2)
        #expect(state.lastCheck == harness.clock.current)
        #expect(state.notifiedUpdateKeys == ["com.a@2.0", "com.b@3.0"])
    }

    @Test("repeat run stays quiet; a new version notifies with the full count")
    func repeatRun() async {
        let harness = Harness(versions: ["com.a": "2.0", "com.b": "3.0"])
        defer { harness.cleanUp() }
        _ = await harness.check.runIfDue()
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 2, notified: false))
        #expect(await harness.notifier.deliveries.count == 1)

        harness.checker.setVersion("com.a", "2.1")
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 2, notified: true))
        #expect(await harness.notifier.deliveries.count == 2)
        #expect(await harness.notifier.deliveries.last?.count == 2)
    }

    @Test("zero updates sends nothing and stores count 0")
    func zeroAvailable() async {
        let harness = Harness(versions: [:])
        defer { harness.cleanUp() }
        #expect(await harness.check.runIfDue() == .checked(availableCount: 0, notified: false))
        #expect(await harness.notifier.deliveries.isEmpty)
        #expect(AppReleaseBackgroundState.storedAvailableCount(in: harness.defaults) == 0)
    }

    @Test("an app whose source failed keeps its announced key and count")
    func failedSourceKeepsKey() async {
        let harness = Harness(versions: ["com.a": "2.0", "com.b": "3.0"])
        defer { harness.cleanUp() }
        _ = await harness.check.runIfDue()

        harness.checker.setFailing(["com.b"])
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 2, notified: false))
        #expect(AppReleaseBackgroundState.stored(in: harness.defaults).notifiedUpdateKeys == ["com.a@2.0", "com.b@3.0"])
        #expect(AppReleaseBackgroundState.storedAvailableCount(in: harness.defaults) == 2)

        harness.checker.setFailing([])
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 2, notified: false))
        #expect(await harness.notifier.deliveries.count == 1)
    }

    @Test("a run where every source failed changes nothing")
    func allFailed() async {
        let harness = Harness(versions: ["com.a": "2.0"])
        defer { harness.cleanUp() }
        _ = await harness.check.runIfDue()
        let before = AppReleaseBackgroundState.stored(in: harness.defaults)

        harness.checker.setFailing(["com.a", "com.b", "com.c"])
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .failed)
        #expect(AppReleaseBackgroundState.stored(in: harness.defaults) == before)
        #expect(AppReleaseBackgroundState.storedAvailableCount(in: harness.defaults) == 1)
        #expect(await harness.notifier.deliveries.count == 1)
    }

    static func disableBackgroundCheck(suite: String) {
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        AppReleasePreferences(ignoredBundleIDs: ["com.c"], backgroundCheckEnabled: false).store(in: defaults)
    }

    @Test("an announced key survives an up-to-date run and is pruned when the app is gone")
    func keyKeptWhileUpToDate() async {
        let harness = Harness(versions: ["com.a": "2", "com.b": "3"])
        defer { harness.cleanUp() }
        _ = await harness.check.runIfDue()

        harness.checker.clearVersion("com.a")
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: false))
        #expect(AppReleaseBackgroundState.stored(in: harness.defaults).notifiedUpdateKeys == ["com.a@2", "com.b@3"])

        harness.checker.setVersion("com.a", "2")
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 2, notified: false))
        #expect(await harness.notifier.deliveries.count == 1)

        harness.checker.setVersion("com.a", "3")
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 2, notified: true))
        #expect(AppReleaseBackgroundState.stored(in: harness.defaults).notifiedUpdateKeys == ["com.a@3", "com.b@3"])

        let clock = harness.clock
        let onlyBravo = AppReleaseBackgroundCheck(
            suiteName: harness.suite,
            inventory: StubInventory(apps: [Self.app("com.b", name: "Bravo")]),
            checker: harness.checker,
            notifier: harness.notifier,
            now: { clock.current }
        )
        harness.clock.advance(hours: 25)
        _ = await onlyBravo.runIfDue()
        #expect(AppReleaseBackgroundState.stored(in: harness.defaults).notifiedUpdateKeys == ["com.b@3"])
    }

    @Test("an undelivered notification leaves its updates unannounced")
    func undeliveredNotRecorded() async {
        let harness = Harness(versions: ["com.a": "2.0", "com.b": "3.0"])
        defer { harness.cleanUp() }
        await harness.notifier.setSucceeds(false)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 2, notified: false))
        let state = AppReleaseBackgroundState.stored(in: harness.defaults)
        #expect(state.notifiedUpdateKeys.isEmpty)
        #expect(state.lastCheck == harness.clock.current)
        #expect(AppReleaseBackgroundState.storedAvailableCount(in: harness.defaults) == 2)

        await harness.notifier.setSucceeds(true)
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 2, notified: true))
        #expect(AppReleaseBackgroundState.stored(in: harness.defaults).notifiedUpdateKeys == ["com.a@2.0", "com.b@3.0"])
    }

    @Test("turning the preference off during the inventory stops before any source is contacted")
    func disabledDuringInventory() async {
        let harness = Harness(versions: ["com.a": "2.0"], onInventory: { Self.disableBackgroundCheck(suite: $0) })
        defer { harness.cleanUp() }
        #expect(await harness.check.runIfDue() == .disabled)
        #expect(harness.checker.calls == 0)
    }

    @Test("turning the preference off during the check notifies and stores nothing")
    func disabledDuringCheck() async {
        let harness = Harness(versions: ["com.a": "2.0"])
        defer { harness.cleanUp() }
        let before = AppReleaseBackgroundState.stored(in: harness.defaults)
        harness.checker.setOnCheck { [suite = harness.suite] in Self.disableBackgroundCheck(suite: suite) }
        #expect(await harness.check.runIfDue() == .disabled)
        #expect(await harness.notifier.deliveries.isEmpty)
        #expect(AppReleaseBackgroundState.stored(in: harness.defaults) == before)
    }

    @Test("preferences stored before backgroundCheckEnabled existed keep their data")
    func oldPreferencesDecode() throws {
        let old = #"{"ignoredBundleIDs":["com.x"],"skippedVersions":{"com.y":"2.0"},"autoCheckEnabled":true}"#
        let decoded = try JSONDecoder().decode(AppReleasePreferences.self, from: Data(old.utf8))
        #expect(decoded.ignoredBundleIDs == ["com.x"])
        #expect(decoded.skippedVersions == ["com.y": "2.0"])
        #expect(decoded.autoCheckEnabled)
        #expect(!decoded.backgroundCheckEnabled)
    }

    @Test("notification text")
    func notificationContent() {
        let one = UserNotificationAppReleaseUpdateNotifier.content(count: 1, appNames: ["Alpha"])
        #expect(one.title == "1 app update available")
        #expect(one.body == "Alpha")
        let five = UserNotificationAppReleaseUpdateNotifier.content(count: 5, appNames: ["A", "B", "C", "D", "E"])
        #expect(five.title == "5 app updates available")
        #expect(five.body == "A, B, C and 2 more")
    }

    @Test("containingAppSuiteName finds the enclosing app's bundle ID, nil outside an app")
    func containingApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Foo.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "com.example.foo"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        let inside = contents.appendingPathComponent("MacOS/Helper")
        #expect(AppReleaseBackgroundCheck.containingAppSuiteName(executable: inside) == "com.example.foo")
        #expect(AppReleaseBackgroundCheck.containingAppSuiteName(executable: root.appendingPathComponent("tool")) == nil)
        #expect(AppReleaseBackgroundCheck.containingAppSuiteName(executable: nil) == nil)
    }
}
