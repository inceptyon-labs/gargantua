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
            var builds: [String: String] = [:]
            var failing: Set<String> = []
            var untracked: Set<String> = []
            var skipped: Set<String> = []
            var selfUpdating: Set<String> = []
            var onCheck: (@Sendable () -> Void)?
        }
        private let state: OSAllocatedUnfairLock<State>
        var calls: Int { state.withLock { $0.calls } }

        init(versions: [String: String]) { state = OSAllocatedUnfairLock(initialState: State(versions: versions)) }

        func setFailing(_ ids: Set<String>) { state.withLock { $0.failing = ids } }

        func setUntracked(_ ids: Set<String>) { state.withLock { $0.untracked = ids } }

        func setSkipped(_ ids: Set<String>) { state.withLock { $0.skipped = ids } }

        func setSelfUpdating(_ ids: Set<String>) { state.withLock { $0.selfUpdating = ids } }

        func setBuild(_ id: String, _ build: String?) { state.withLock { $0.builds[id] = build } }

        func setVersion(_ id: String, _ version: String) { state.withLock { $0.versions[id] = version } }

        func clearVersion(_ id: String) { state.withLock { $0.versions[id] = nil } }

        func setOnCheck(_ action: @escaping @Sendable () -> Void) { state.withLock { $0.onCheck = action } }

        func check(_ apps: [InstalledApp], preferences: AppReleasePreferences) async -> [AppReleaseRow] {
            let (versions, builds, failing, untracked, skipped, onCheck, selfUpdating) = state.withLock { state in
                state.calls += 1
                return (state.versions, state.builds, state.failing, state.untracked, state.skipped, state.onCheck, state.selfUpdating)
            }
            onCheck?()
            return apps.map { app in
                // Same order as the real resolver: opt-outs before failures.
                if preferences.ignoredBundleIDs.contains(app.bundleID) {
                    return AppReleaseRow(app: app, status: .ignored)
                }
                if untracked.contains(app.bundleID) { return AppReleaseRow(app: app, status: .untracked) }
                if skipped.contains(app.bundleID) { return AppReleaseRow(app: app, status: .skippedVersion("9")) }
                if failing.contains(app.bundleID) { return AppReleaseRow(app: app, status: .failed("offline")) }
                guard let version = versions[app.bundleID] else {
                    return AppReleaseRow(app: app, status: .upToDate(latest: nil))
                }
                let candidate = AppReleaseCandidate(
                    source: .sparkle,
                    version: AppReleaseVersion(short: version, build: builds[app.bundleID]),
                    downloadURL: nil
                )
                if selfUpdating.contains(app.bundleID) {
                    return AppReleaseRow(app: app, status: .available(candidate, .updatesItself(AppReleaseSelfUpdater(productID: "x"))))
                }
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

        init(
            versions: [String: String],
            enabled: Bool = true,
            ignored: Set<String> = ["com.c"],
            extraApps: [InstalledApp] = [],
            onInventory: (@Sendable (String) -> Void)? = nil) {
            defaults = UserDefaults(suiteName: suite)!
            checker = StubChecker(versions: versions)
            AppReleasePreferences(ignoredBundleIDs: ignored, backgroundCheckEnabled: enabled).store(in: defaults)
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
                ] + extraApps, onCall: inventoryHook),
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
        #expect(state.announcedVersions.mapValues(\.description) == ["com.a": "2.0", "com.b": "3.0"])
    }

    @Test("an app that updates itself is neither announced nor counted")
    func selfUpdatingNotAnnounced() async {
        let harness = Harness(versions: ["com.a": "2.0", "com.b": "3.0"])
        defer { harness.cleanUp() }
        harness.checker.setSelfUpdating(["com.b"])
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: true))
        #expect(await harness.notifier.deliveries.first?.names == ["Alpha"])
        #expect(AppReleaseBackgroundState.storedAvailableCount(in: harness.defaults) == 1)
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

    @Test("an app whose source failed is not re-announced on recovery and not counted while failed")
    func failedSourceKeepsAnnouncement() async {
        let harness = Harness(versions: ["com.a": "2.0", "com.b": "3.0"])
        defer { harness.cleanUp() }
        _ = await harness.check.runIfDue()

        harness.checker.setFailing(["com.b"])
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: false))
        #expect(AppReleaseBackgroundState.storedAvailableCount(in: harness.defaults) == 1)
        #expect(AppReleaseBackgroundState.stored(in: harness.defaults).announcedVersions.keys.sorted() == ["com.a", "com.b"])

        harness.checker.setFailing([])
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 2, notified: false))
        #expect(await harness.notifier.deliveries.count == 1)
    }
}

extension AppReleaseBackgroundCheckTests {
    @Test("a run where every source failed changes nothing")
    func allFailed() async {
        let harness = Harness(versions: ["com.a": "2.0"])
        defer { harness.cleanUp() }
        _ = await harness.check.runIfDue()
        let before = AppReleaseBackgroundState.stored(in: harness.defaults)

        harness.checker.setFailing(["com.a", "com.b", "com.c"])
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .failed)
        var after = AppReleaseBackgroundState.stored(in: harness.defaults)
        #expect(after.consecutiveFailedRuns == 1)
        after.consecutiveFailedRuns = 0
        #expect(after == before)
        #expect(AppReleaseBackgroundState.storedAvailableCount(in: harness.defaults) == 1)
        #expect(await harness.notifier.deliveries.count == 1)
    }

    static func disableBackgroundCheck(suite: String) {
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        AppReleasePreferences(ignoredBundleIDs: ["com.c"], backgroundCheckEnabled: false).store(in: defaults)
    }

    @Test("up-to-date then available again at the same version is not re-announced; a newer one is")
    func sameVersionAfterUpToDate() async {
        let harness = Harness(versions: ["com.a": "2.0"])
        defer { harness.cleanUp() }
        _ = await harness.check.runIfDue()

        harness.checker.clearVersion("com.a")
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 0, notified: false))

        harness.checker.setVersion("com.a", "2.0")
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: false))
        #expect(await harness.notifier.deliveries.count == 1)

        harness.checker.setVersion("com.a", "3.0")
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: true))
        #expect(await harness.notifier.deliveries.count == 2)
    }

    @Test("the same release with and without a build number is announced once")
    func shortOnlyVersusShortPlusBuild() async {
        let harness = Harness(versions: ["com.a": "2.0"])
        defer { harness.cleanUp() }
        _ = await harness.check.runIfDue()

        harness.checker.setBuild("com.a", "200")
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: false))
        #expect(await harness.notifier.deliveries.count == 1)
    }

    @Test("an app removed from the inventory loses its announced entry")
    func prunedWhenUninstalled() async {
        let harness = Harness(versions: ["com.a": "2", "com.b": "3"])
        defer { harness.cleanUp() }
        _ = await harness.check.runIfDue()

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
        #expect(AppReleaseBackgroundState.stored(in: harness.defaults).announcedVersions.keys.sorted() == ["com.b"])
    }

    @Test("count and notification names agree")
    func countMatchesNames() async {
        let harness = Harness(versions: ["com.a": "2.0", "com.b": "3.0"])
        defer { harness.cleanUp() }
        _ = await harness.check.runIfDue()
        harness.checker.setFailing(["com.b"])
        harness.checker.setVersion("com.a", "2.1")
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: true))
        let last = await harness.notifier.deliveries.last
        #expect(last?.count == 1)
        #expect(last?.names == ["Alpha"])
    }

    @Test("a run where most queried sources failed is retried: nothing stored, lastCheck unchanged")
    func mostlyFailed() async {
        let harness = Harness(versions: ["com.a": "2.0"])
        defer { harness.cleanUp() }
        _ = await harness.check.runIfDue()
        let before = AppReleaseBackgroundState.stored(in: harness.defaults)

        // com.c is ignored, so com.a and com.b are the queried rows: 2 of 2 failed.
        harness.checker.setFailing(["com.a", "com.b"])
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .failed)
        var after = AppReleaseBackgroundState.stored(in: harness.defaults)
        after.consecutiveFailedRuns = 0
        #expect(after == before)
    }

    @Test("a minority of failures is a normal run")
    func minorityFailed() async {
        let harness = Harness(versions: ["com.a": "2.0"])
        defer { harness.cleanUp() }
        harness.checker.setFailing(["com.b"])
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: true))
    }

    @Test("ignored and untracked rows are excluded from the failure ratio")
    func optOutsExcludedFromRatio() async {
        let harness = Harness(versions: [:])
        defer { harness.cleanUp() }
        // com.c ignored, com.a untracked, com.b failed: 1 of 1 queried failed.
        harness.checker.setUntracked(["com.a"])
        harness.checker.setFailing(["com.b", "com.c"])
        #expect(await harness.check.runIfDue() == .failed)

        // With com.b healthy nothing queried failed, though ignored com.c is marked failing.
        harness.checker.setFailing(["com.c"])
        #expect(await harness.check.runIfDue() == .checked(availableCount: 0, notified: false))
    }

    @Test("an undelivered notification leaves its updates unannounced")
    func undeliveredNotRecorded() async {
        let harness = Harness(versions: ["com.a": "2.0", "com.b": "3.0"])
        defer { harness.cleanUp() }
        await harness.notifier.setSucceeds(false)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 2, notified: false))
        let state = AppReleaseBackgroundState.stored(in: harness.defaults)
        #expect(state.announcedVersions.isEmpty)
        #expect(state.lastCheck == harness.clock.current)
        #expect(AppReleaseBackgroundState.storedAvailableCount(in: harness.defaults) == 2)

        await harness.notifier.setSucceeds(true)
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 2, notified: true))
        #expect(AppReleaseBackgroundState.stored(in: harness.defaults).announcedVersions.count == 2)
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

    @Test("a build reported later for an announced build-less version is recorded, so the next build notifies")
    func buildEnrichment() async {
        let harness = Harness(versions: ["com.a": "2.0"])
        defer { harness.cleanUp() }
        _ = await harness.check.runIfDue()

        harness.checker.setBuild("com.a", "200")
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: false))
        let stored = AppReleaseBackgroundState.stored(in: harness.defaults).announcedVersions["com.a"]
        #expect(stored == AppReleaseVersion(short: "2.0", build: "200"))

        harness.checker.setBuild("com.a", "201")
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: true))
        #expect(await harness.notifier.deliveries.count == 2)
    }

    @Test("mostly failed runs are retried three times, then the check runs normally")
    func boundedRetries() async {
        let delta = Self.app("com.d", name: "Delta")
        let harness = Harness(versions: ["com.a": "2.0"], extraApps: [delta])
        defer { harness.cleanUp() }
        // Queried: a, b, d (c is ignored); b and d fail.
        harness.checker.setFailing(["com.b", "com.d"])
        let lastCheck = AppReleaseBackgroundState.stored(in: harness.defaults).lastCheck
        for expected in 1 ... 3 {
            #expect(await harness.check.runIfDue() == .failed)
            let state = AppReleaseBackgroundState.stored(in: harness.defaults)
            #expect(state.consecutiveFailedRuns == expected)
            #expect(state.lastCheck == lastCheck)
        }
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: true))
        let state = AppReleaseBackgroundState.stored(in: harness.defaults)
        #expect(state.lastCheck == harness.clock.current)
        #expect(state.consecutiveFailedRuns == 0)
        #expect(await harness.notifier.deliveries.last?.names == ["Alpha"])
    }

    @Test("zero queried rows is a normal run")
    func zeroQueried() async {
        let harness = Harness(versions: [:], ignored: ["com.a", "com.b", "com.c"])
        defer { harness.cleanUp() }
        harness.checker.setFailing(["com.a", "com.b", "com.c"])
        #expect(await harness.check.runIfDue() == .checked(availableCount: 0, notified: false))
        #expect(AppReleaseBackgroundState.stored(in: harness.defaults).consecutiveFailedRuns == 0)
    }

    @Test("a skipped version row is excluded from the failure ratio")
    func skippedExcludedFromRatio() async {
        let harness = Harness(versions: [:])
        defer { harness.cleanUp() }
        harness.checker.setFailing(["com.b"])
        harness.checker.setSkipped(["com.a"])
        // Queried: com.b only (com.c ignored, com.a skipped): 1 of 1 failed.
        #expect(await harness.check.runIfDue() == .failed)
        harness.checker.setFailing([])
        // Nothing queried failed; a skipped row doesn't count either way.
        #expect(await harness.check.runIfDue() == .checked(availableCount: 0, notified: false))
    }
}
