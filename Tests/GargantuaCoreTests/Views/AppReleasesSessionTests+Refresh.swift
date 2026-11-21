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

    @Test("An install records which bundle version the release held, also when that version or a newer one was installed")
    func installConfirmsRelease() async throws {
        let id = Self.app.bundleID
        let fixture = Self.makeFixture()
        await fixture.session.check()
        await fixture.session.install(try #require(fixture.session.rows.first), quitIfRunning: false)
        let offered = Self.candidate.version.description
        #expect(AppReleasePreferences.stored(in: fixture.defaults).confirmedReleases[id]
            == AppReleaseConfirmedRelease(offered: offered, installed: offered, source: Self.candidate.source))

        // The download turns out to hold the installed version: current, not a failure.
        let same = Self.makeFixture()
        let installed = AppReleaseVersion(short: "1.0", build: nil)
        same.installer.failure = .verification(.notNewer(staged: installed, installed: installed))
        await same.session.check()
        await same.session.install(try #require(same.session.rows.first), quitIfRunning: false)
        #expect(AppReleasePreferences.stored(in: same.defaults).confirmedReleases[id]
            == AppReleaseConfirmedRelease(offered: offered, installed: "1.0", source: Self.candidate.source))
        guard case .installed = same.session.rowMessages[id] else {
            Issue.record("expected an up-to-date message, got \(String(describing: same.session.rowMessages[id]))")
            return
        }

        // An older download: the app updated itself past this release.
        let older = Self.makeFixture()
        older.installer.failure = .verification(.notNewer(staged: AppReleaseVersion(short: "0.9", build: nil), installed: installed))
        await older.session.check()
        await older.session.install(try #require(older.session.rows.first), quitIfRunning: false)
        #expect(AppReleasePreferences.stored(in: older.defaults).confirmedReleases[id]
            == AppReleaseConfirmedRelease(offered: offered, installed: "1.0", source: Self.candidate.source))
        #expect(older.session.rowMessages[id] == .installed("Already up to date. The installed version is newer than this release."))

        // A download that can't be ordered against the installed copy is still a failure.
        let unordered = Self.makeFixture()
        unordered.installer.failure = .verification(.notNewer(
            staged: AppReleaseVersion(short: "1.0", build: "abc"),
            installed: AppReleaseVersion(short: "1.0", build: "def")
        ))
        await unordered.session.check()
        await unordered.session.install(try #require(unordered.session.rows.first), quitIfRunning: false)
        #expect(AppReleasePreferences.stored(in: unordered.defaults).confirmedReleases.isEmpty)
        guard case .failed = unordered.session.rowMessages[id] else {
            Issue.record("expected a failure message")
            return
        }
    }

    @Test("An app that updated itself to the offered version records the release; a later version doesn't")
    func updatedMeanwhileConfirmsOnlyTheSameVersion() async throws {
        let id = Self.app.bundleID
        let staged = Self.candidate.version
        let same = Self.makeFixture()
        same.installer.failure = .updatedMeanwhile(to: staged, staged: staged)
        await same.session.check()
        await same.session.install(try #require(same.session.rows.first), quitIfRunning: false)
        #expect(AppReleasePreferences.stored(in: same.defaults).confirmedReleases[id]
            == AppReleaseConfirmedRelease(offered: staged.description, installed: staged.description, source: Self.candidate.source))
        #expect(same.session.recentlyInstalled.contains(id))

        let later = Self.makeFixture()
        later.installer.failure = .updatedMeanwhile(to: AppReleaseVersion(short: "9.9", build: nil), staged: staged)
        await later.session.check()
        await later.session.install(try #require(later.session.rows.first), quitIfRunning: false)
        #expect(AppReleasePreferences.stored(in: later.defaults).confirmedReleases.isEmpty)
        guard case .installed = later.session.rowMessages[id] else {
            Issue.record("expected an up-to-date message, got \(String(describing: later.session.rowMessages[id]))")
            return
        }
    }

    @Test("A change of signer waits on the row; approving stores it and installs")
    func signerChangeIsApproved() async throws {
        let id = Self.app.bundleID
        let change = AppReleaseSignerChange(fromTeamID: "TEAM123456", toTeamID: "NEWTEAM123")
        let fixture = Self.makeFixture()
        fixture.installer.failure = .signerChanged(change)
        await fixture.session.check()
        await fixture.session.install(try #require(fixture.session.rows.first), quitIfRunning: false)
        #expect(fixture.session.rowMessages[id] == .signerChanged(change))
        #expect(AppReleasePreferences.stored(in: fixture.defaults).approvedSigners.isEmpty)
        #expect(fixture.session.availableCount == 1)

        fixture.installer.failure = nil
        await fixture.session.approveSigner(change, for: id, quitIfRunning: false)
        #expect(AppReleasePreferences.stored(in: fixture.defaults).approvedSigners[id] == [change])
        #expect(fixture.installer.calls.count == 2)
        guard case .installed = fixture.session.rowMessages[id] else {
            Issue.record("expected the update to install after approval")
            return
        }
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
