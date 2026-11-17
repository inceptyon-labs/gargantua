import Foundation
import Testing
@testable import GargantuaCore

extension AppReleaseBackgroundCheckTests {
    @Test("an in-app check counts toward the interval")
    func inAppClockCounts() async {
        let harness = Harness(versions: [:])
        defer { harness.cleanUp() }
        let key = AppReleaseBackgroundState.inAppKey
        AppReleaseBackgroundState(lastCheck: harness.clock.current.addingTimeInterval(-3600)).store(in: harness.defaults, key: key)
        #expect(await harness.check.runIfDue() == .notDue)
        #expect(harness.checker.calls == 0)
        AppReleaseBackgroundState(lastCheck: harness.clock.current.addingTimeInterval(-25 * 3600)).store(in: harness.defaults, key: key)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 0, notified: false))
        #expect(harness.checker.calls == 1)
    }

    @Test("a version already seen in the app is not notified; a newer one is")
    func inAppSeenVersions() async {
        let harness = Harness(versions: ["com.a": "2.0"])
        defer { harness.cleanUp() }
        let seen = AppReleaseBackgroundState(announcedVersions: ["com.a": AppReleaseVersion(short: "2.0", build: nil)])
        seen.store(in: harness.defaults, key: AppReleaseBackgroundState.inAppKey)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: false))
        #expect(await harness.notifier.deliveries.isEmpty)
        harness.checker.setVersion("com.a", "2.1")
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: true))
        #expect(await harness.notifier.deliveries.last?.count == 1)
    }

    @Test("either clock being recent blocks the run")
    func newestClockWins() async {
        let harness = Harness(versions: [:])
        defer { harness.cleanUp() }
        AppReleaseBackgroundState(lastCheck: harness.clock.current.addingTimeInterval(-25 * 3600)).store(in: harness.defaults)
        AppReleaseBackgroundState(lastCheck: harness.clock.current.addingTimeInterval(-3600))
            .store(in: harness.defaults, key: AppReleaseBackgroundState.inAppKey)
        #expect(await harness.check.runIfDue() == .notDue)
        #expect(harness.checker.calls == 0)
    }

    @Test("a future check time does not block the run")
    func futureClockIgnored() async {
        let harness = Harness(versions: [:])
        defer { harness.cleanUp() }
        AppReleaseBackgroundState(lastCheck: harness.clock.current.addingTimeInterval(3600))
            .store(in: harness.defaults, key: AppReleaseBackgroundState.inAppKey)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 0, notified: false))
        #expect(harness.checker.calls == 1)
    }

    @Test("a version marked seen during the sweep is not notified")
    func seenDuringSweep() async {
        let harness = Harness(versions: ["com.a": "2.0"])
        defer { harness.cleanUp() }
        let suite = harness.suite
        harness.checker.setOnCheck {
            AppReleaseBackgroundState(announcedVersions: ["com.a": AppReleaseVersion(short: "2.0", build: nil)])
                .store(in: UserDefaults(suiteName: suite)!, key: AppReleaseBackgroundState.inAppKey)
        }
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: false))
        #expect(await harness.notifier.deliveries.isEmpty)
    }

    @Test("an app seen in the app doesn't hide another app's new version")
    func seenPlusNew() async {
        let harness = Harness(versions: ["com.a": "2.0", "com.b": "3.0"])
        defer { harness.cleanUp() }
        let seen = AppReleaseBackgroundState(announcedVersions: ["com.a": AppReleaseVersion(short: "2.0", build: nil)])
        seen.store(in: harness.defaults, key: AppReleaseBackgroundState.inAppKey)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 2, notified: true))
        #expect(await harness.notifier.deliveries.count == 1)
    }

    @Test("a hand-off the app posts after the run stopped waiting is not announced again")
    func latePostIsNotRepeated() async {
        let harness = Harness(versions: ["com.a": "2.0"])
        defer { harness.cleanUp() }
        await harness.notifier.setSucceeds(false)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: false))
        #expect(AppReleaseBackgroundState.stored(in: harness.defaults).unconfirmedVersions.keys.sorted() == ["com.a"])

        // The app posts it once the user answers the permission prompt.
        let pending = AppReleaseAnnouncement(count: 1, appNames: ["Alpha"])
        pending.storePending(in: harness.defaults)
        harness.defaults.set(pending.id.uuidString, forKey: AppReleaseAnnouncement.postedKey)
        await harness.notifier.setSucceeds(true)
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: false))
        #expect(await harness.notifier.deliveries.count == 1)
        #expect(AppReleaseBackgroundState.stored(in: harness.defaults).unconfirmedVersions.isEmpty)
    }

    @Test("with notifications turned off the versions count as announced, so the app isn't opened every day")
    func refusedHandOffIsNotRetried() async {
        let harness = Harness(versions: ["com.a": "2.0"])
        defer { harness.cleanUp() }
        // What the app records when it finds notifications off for the pending hand-off.
        let pending = AppReleaseAnnouncement(count: 1, appNames: ["Alpha"])
        pending.storePending(in: harness.defaults)
        harness.defaults.set(pending.id.uuidString, forKey: AppReleaseAnnouncement.refusedKey)
        await harness.notifier.setSucceeds(false)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: false))
        harness.clock.advance(hours: 25)
        #expect(await harness.check.runIfDue() == .checked(availableCount: 1, notified: false))
        #expect(await harness.notifier.deliveries.count == 1)
    }
}
