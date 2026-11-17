import Foundation
import Testing
@testable import GargantuaCore

@Suite("AppReleasesSession preference changes")
@MainActor
struct AppReleasesSessionPreferenceTests {
    typealias Base = AppReleasesSessionTests

    /// Resolves ignored and skipped like the real checker, and holds only the
    /// numbered calls in `gatedCalls`.
    actor PreferenceChecker: AppReleaseChecking {
        private(set) var calls = 0
        private let gatedCalls: Set<Int>
        private let gate = Base.CheckGate()

        private let candidate: AppReleaseCandidate

        init(gatedCalls: Set<Int>, candidate: AppReleaseCandidate) {
            self.gatedCalls = gatedCalls
            self.candidate = candidate
        }

        func open() async { await gate.open() }

        func check(_ apps: [InstalledApp], preferences: AppReleasePreferences) async -> [AppReleaseRow] {
            calls += 1
            let call = calls
            if gatedCalls.contains(call) { await gate.wait() }
            return apps.map { app in
                if preferences.ignoredBundleIDs.contains(app.bundleID) {
                    return AppReleaseRow(app: app, status: .ignored)
                }
                if let skipped = preferences.skippedVersions[app.bundleID] {
                    return AppReleaseRow(app: app, status: .skippedVersion(skipped))
                }
                return AppReleaseRow(app: app, status: .available(candidate, .inPlace))
            }
        }
    }

    static func makePreferenceSession(gatedCalls: Set<Int>) -> (AppReleasesSession, PreferenceChecker) {
        let checker = PreferenceChecker(gatedCalls: gatedCalls, candidate: Base.candidate)
        let session = AppReleasesSession(
            inventory: Base.StubInventory(apps: [Base.app]),
            checker: checker,
            installer: Base.StubInstaller(),
            authorize: { .success(.unchecked($0)) },
            quitter: Base.StubQuitter(running: false),
            now: Date.init,
            defaults: Base.makeDefaults()
        )
        return (session, checker)
    }

    @Test("An app un-ignored while a check runs is resolved again when the check finishes")
    func unignoreDuringCheckSurvives() async {
        let (session, checker) = Self.makePreferenceSession(gatedCalls: [2])
        await session.check()
        session.ignore(Base.app.bundleID)

        let run = Task { await session.check() }
        await Base.waitUntil { await checker.calls == 2 }
        await session.unignore(Base.app.bundleID)
        await checker.open()
        await run.value

        // Calls: initial check, gated full check, unignore's refresh. The
        // row unignore already resolved is kept, so no fourth call.
        #expect(session.rows.first?.status == .available(Base.candidate, .inPlace))
        #expect(await checker.calls == 3)
        #expect(session.phase == .ready)
    }

    @Test("A row already re-resolved mid-check is not checked again when the check finishes")
    func reresolvedRowNotRechecked() async {
        let (session, checker) = Self.makePreferenceSession(gatedCalls: [2])
        await session.check()
        session.ignore(Base.app.bundleID)

        let run = Task { await session.check() }
        await Base.waitUntil { await checker.calls == 2 }
        await session.unignore(Base.app.bundleID)
        #expect(session.rows.first?.status == .available(Base.candidate, .inPlace))
        await checker.open()
        await run.value

        #expect(session.rows.first?.status == .available(Base.candidate, .inPlace))
        #expect(await checker.calls == 3)
    }

    @Test("A version un-skipped while a check runs is resolved again when the check finishes")
    func unskipDuringCheckSurvives() async {
        let (session, checker) = Self.makePreferenceSession(gatedCalls: [2])
        await session.check()
        session.skip(version: Base.candidate.displayVersion, for: Base.app.bundleID)

        let run = Task { await session.check() }
        await Base.waitUntil { await checker.calls == 2 }
        await session.unskip(Base.app.bundleID)
        await checker.open()
        await run.value

        // Calls: initial check, gated full check, unskip's refresh. The row
        // unskip already resolved is kept, so no fourth call.
        #expect(session.rows.first?.status == .available(Base.candidate, .inPlace))
        #expect(await checker.calls == 3)
        #expect(session.phase == .ready)
    }

    @Test("An app ignored while its re-check runs stays ignored")
    func ignoreDuringRefreshSurvives() async {
        let (session, checker) = Self.makePreferenceSession(gatedCalls: [2])
        await session.check()
        session.skip(version: Base.candidate.displayVersion, for: Base.app.bundleID)

        let unskip = Task { await session.unskip(Base.app.bundleID) }
        await Base.waitUntil { await checker.calls == 2 }
        session.ignore(Base.app.bundleID)
        await checker.open()
        await unskip.value

        #expect(session.rows.first?.status == .ignored)
    }

    @Test("An app un-ignored while its re-check runs is not left ignored")
    func unignoreDuringRefreshSurvives() async {
        let (session, checker) = Self.makePreferenceSession(gatedCalls: [2])
        await session.check()
        session.ignore(Base.app.bundleID)

        // Unskipping an ignored app re-checks it while it is still ignored.
        let unskip = Task { await session.unskip(Base.app.bundleID) }
        await Base.waitUntil { await checker.calls == 2 }
        await session.unignore(Base.app.bundleID)
        await checker.open()
        await unskip.value

        #expect(session.rows.first?.status == .available(Base.candidate, .inPlace))
    }
}
