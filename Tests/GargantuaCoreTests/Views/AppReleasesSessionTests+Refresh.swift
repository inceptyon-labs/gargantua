import Foundation
import Testing
@testable import GargantuaCore

extension AppReleasesSessionTests {

    /// Answers each numbered call with its scripted status (the last one
    /// repeats) and holds only the calls in `gatedCalls`.
    actor SequencedChecker: AppReleaseChecking {
        private(set) var calls = 0
        private(set) var returns = 0
        private let statuses: [AppReleaseStatus]
        private let gatedCalls: Set<Int>
        private let gate = CheckGate()

        init(statuses: [AppReleaseStatus], gatedCalls: Set<Int>) {
            self.statuses = statuses
            self.gatedCalls = gatedCalls
        }

        func open() async { await gate.open() }

        func check(_ apps: [InstalledApp], preferences: AppReleasePreferences) async -> [AppReleaseRow] {
            calls += 1
            let call = calls
            if gatedCalls.contains(call) { await gate.wait() }
            returns += 1
            let status = statuses[min(call, statuses.count) - 1]
            return apps.map { AppReleaseRow(app: $0, status: status) }
        }
    }

    static func makeSequencedSession(
        statuses: [AppReleaseStatus],
        gatedCalls: Set<Int>
    ) -> (AppReleasesSession, SequencedChecker) {
        let checker = SequencedChecker(statuses: statuses, gatedCalls: gatedCalls)
        let session = AppReleasesSession(
            inventory: StubInventory(apps: [app]),
            checker: checker,
            installer: StubInstaller(),
            authorize: { .success(.unchecked($0)) },
            quitter: StubQuitter(running: false),
            now: Date.init,
            defaults: makeDefaults()
        )
        return (session, checker)
    }

    @Test("An older re-check of an app can't overwrite a newer one")
    func olderRefreshDropped() async {
        let newer = AppReleaseStatus.upToDate(latest: Self.candidate)
        let (session, checker) = Self.makeSequencedSession(
            statuses: [.available(Self.candidate, .inPlace), .untracked, newer], gatedCalls: [2]
        )
        await session.check()

        let first = Task { await session.unskip(Self.app.bundleID) }
        await Self.waitUntil { await checker.calls == 2 }
        await session.unignore(Self.app.bundleID)
        #expect(session.rows.first?.status == newer)
        await checker.open()
        await first.value

        #expect(session.rows.first?.status == newer)
    }

    @Test("A re-check that finishes after the results were released leaves the list empty")
    func refreshAfterReleaseDropped() async {
        let (session, checker) = Self.makeSequencedSession(
            statuses: [.available(Self.candidate, .inPlace)], gatedCalls: [2]
        )
        await session.check()

        let refresh = Task { await session.unskip(Self.app.bundleID) }
        await Self.waitUntil { await checker.calls == 2 }
        session.releaseResults()
        await checker.open()
        await refresh.value

        #expect(session.rows.isEmpty)
    }

    @Test("A cancelled check's re-check loop doesn't write its row")
    func cancelledRecheckLoopDropped() async {
        // The checker reports an ignore the preferences no longer hold, so
        // the check's own re-check (call 2) is the one held.
        let (session, checker) = Self.makeSequencedSession(
            statuses: [.ignored, .upToDate(latest: Self.candidate)], gatedCalls: [2]
        )
        session.startCheck()
        await Self.waitUntil { await checker.calls == 2 }
        session.cancelCheck()
        await checker.open()
        await Self.waitUntil { await checker.returns == 2 }
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(session.rows.first?.status == .ignored)
        #expect(session.phase == .idle)
    }

    @Test("An automatic check where most sources failed is tried again instead of using up the day")
    func failedAutoCheckIsRetried() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let defaults = Self.makeDefaults()
        AppReleasePreferences(autoCheckEnabled: true).store(in: defaults)
        let fixture = Self.makeFixture(steps: [(0, .failed("offline"))], now: { start }, defaults: defaults)

        await fixture.session.checkIfAutoDue()
        #expect(fixture.session.failedCount == 1)
        #expect(AppReleasePreferences.stored(in: defaults).lastAutoCheck == nil)

        await fixture.session.checkIfAutoDue()
        #expect(await fixture.script.calls == 2)
        #expect(fixture.session.availableCount == 1)
        #expect(AppReleasePreferences.stored(in: defaults).lastAutoCheck == start)
    }

    @Test("Quit consent follows whether the app is running now, not when it was checked")
    func quitConsentIsLive() async throws {
        var running = Self.app
        running = InstalledApp(bundleID: running.bundleID, name: running.name, url: running.url, isRunning: true)
        let session = AppReleasesSession(
            inventory: StubInventory(apps: [running]),
            checker: ScriptedChecker(script: CheckerScript(fallback: .available(Self.candidate, .inPlace))),
            installer: StubInstaller(),
            authorize: { .success(.unchecked($0)) },
            quitter: StubQuitter(running: false),
            defaults: Self.makeDefaults()
        )
        await session.check()
        let row = try #require(session.rows.first)
        #expect(row.app.isRunning)
        #expect(!session.requiresQuitConsent(row))
    }
}
