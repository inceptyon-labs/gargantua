import Foundation
import GargantuaLicensing
import os
import Testing
@testable import GargantuaCore

private let updateStatus = AppReleaseStatus.available(
    AppReleaseCandidate(
        source: .sparkle,
        version: AppReleaseVersion(short: "2.0", build: nil),
        downloadURL: URL(string: "https://example.com/Tool-2.0.zip")
    ),
    .inPlace
)

private func makeApp(_ name: String) -> InstalledApp {
    InstalledApp(
        bundleID: "com.example.\(name.lowercased())",
        name: name,
        url: URL(fileURLWithPath: "/Applications/\(name).app"),
        shortVersion: "1.0",
        teamID: "TEAM123456"
    )
}

@Suite("App Updates: Update All")
@MainActor
struct AppReleasesUpdateAllTests {
    typealias Stubs = AppReleasesSessionTests

    /// Records each install; while `gate` is set, installs wait for it.
    @MainActor
    final class RecordingInstaller: AppReleaseInstalling {
        private(set) var calls: [(bundleID: String, quitIfRunning: Bool)] = []
        private(set) var running = 0
        private(set) var mostRunning = 0
        var gate: Stubs.CheckGate?
        var failures: [String: AppReleaseInstallError] = [:]

        // swiftlint:disable:next function_parameter_count
        func install(
            app: InstalledApp,
            candidate: AppReleaseCandidate,
            strategy: AppReleaseInstallStrategy,
            quitIfRunning: Bool,
            authorization: DestructiveActionAuthorization,
            progress: @escaping @MainActor @Sendable (AppReleaseInstallPhase) -> Void
        ) async -> Result<AppReleaseInstallResult, AppReleaseInstallError> {
            calls.append((app.bundleID, quitIfRunning))
            running += 1
            mostRunning = max(mostRunning, running)
            await gate?.wait()
            await Task.yield()
            running -= 1
            if let failure = failures[app.bundleID] { return .failure(failure) }
            return .success(AppReleaseInstallResult(
                installedVersion: candidate.version, previousCopyInTrash: nil, relaunched: false
            ))
        }
    }

    struct OpenApps: AppReleaseAppQuitting {
        let open: Set<String>
        func isRunning(bundleID: String) -> Bool { open.contains(bundleID) }
        func quitGracefully(bundleID: String, timeout: TimeInterval) async -> Bool { true }
        func relaunch(at url: URL) async -> Bool { true }
    }

    /// Holds checks back once closed, until opened again.
    actor CheckHold {
        private var gate: Stubs.CheckGate?
        private(set) var waiting = 0

        func close() { gate = Stubs.CheckGate() }

        func open() async {
            await gate?.open()
            gate = nil
        }

        func pass() async {
            guard let gate else { return }
            waiting += 1
            await gate.wait()
        }
    }

    /// Gives each app the status its name maps to.
    struct PerAppChecker: AppReleaseChecking {
        let statuses: [String: AppReleaseStatus]
        let hold: CheckHold
        func check(_ apps: [InstalledApp], preferences: AppReleasePreferences) async -> [AppReleaseRow] {
            await hold.pass()
            return apps.map { app in
                let status = preferences.ignoredBundleIDs.contains(app.bundleID)
                    ? .ignored : statuses[app.bundleID] ?? updateStatus
                return AppReleaseRow(app: app, status: status)
            }
        }
    }

    private static let apps = ["Alpha", "Beta", "Gamma"].map(makeApp)
    private static let ids = apps.map(\.bundleID)

    private struct Fixture {
        let session: AppReleasesSession
        let installer: RecordingInstaller
        let hold: CheckHold
    }

    private func makeFixture(
        statuses: [String: AppReleaseStatus] = [:],
        open: Set<String> = [],
        authorize: @escaping @Sendable (DestructiveSurface) async -> DestructiveAuthorizationResult = { .success(.unchecked($0)) }
    ) async -> Fixture {
        let installer = RecordingInstaller()
        let hold = CheckHold()
        let session = AppReleasesSession(
            inventory: Stubs.StubInventory(apps: Self.apps),
            checker: PerAppChecker(statuses: statuses, hold: hold),
            installer: installer,
            authorize: authorize,
            quitter: OpenApps(open: open),
            defaults: Stubs.makeDefaults()
        )
        await session.check()
        return Fixture(session: session, installer: installer, hold: hold)
    }

    @Test("every installable row updates, one at a time, in list order")
    func updatesInOrderOneAtATime() async {
        let fixture = await makeFixture()

        await fixture.session.updateAll(fixture.session.updatableRows, quitting: [])

        #expect(fixture.installer.calls.map(\.bundleID) == Self.ids)
        #expect(fixture.installer.mostRunning == 1)
        #expect(fixture.session.installPhases.isEmpty)
        #expect(fixture.session.batch == nil)
        #expect(fixture.session.batchSummary == AppReleaseBatchSummary(updated: 3))
    }

    @Test("App Store and link-only rows are left out; Homebrew upgrades are included")
    func onlyInstallableRows() async throws {
        let store = try #require(URL(string: "https://apps.apple.com/app/id1"))
        let fixture = await makeFixture(statuses: [
            Self.ids[0]: .available(Stubs.candidate, .openAppStore(store)),
            Self.ids[1]: .available(Stubs.candidate, .linkOnly(nil, reason: .rootOwned)),
            Self.ids[2]: .available(Stubs.candidate, .brewUpgrade(token: "gamma")),
        ])

        #expect(fixture.session.updatableRows.map(\.id) == [Self.ids[2]])
    }

    @Test("a search narrows what Update All covers")
    func searchNarrowsRows() async {
        let fixture = await makeFixture()
        fixture.session.query = "beta"
        #expect(fixture.session.updatableRows.map(\.id) == [Self.ids[1]])
    }

    @Test("only the apps the user agreed to quit are quit")
    func quitConsentIsPerApp() async {
        let fixture = await makeFixture(open: [Self.ids[0], Self.ids[1]])

        await fixture.session.updateAll(fixture.session.updatableRows, quitting: [Self.ids[0]])

        #expect(fixture.installer.calls.map(\.bundleID) == [Self.ids[0], Self.ids[2]])
        #expect(fixture.installer.calls.first?.quitIfRunning == true)
        #expect(fixture.installer.calls.last?.quitIfRunning == false)
        #expect(fixture.session.rowMessages[Self.ids[1]] == .failed("Beta is open. Quit it, then try again."))
        #expect(fixture.session.batchSummary == AppReleaseBatchSummary(updated: 2, needAttention: 1))
    }

    @Test("a failed app doesn't stop the others")
    func failureContinues() async {
        let fixture = await makeFixture()
        fixture.installer.failures[Self.ids[0]] = .installedAppChanged

        await fixture.session.updateAll(fixture.session.updatableRows, quitting: [])

        #expect(fixture.installer.calls.count == 3)
        #expect(fixture.session.batchSummary == AppReleaseBatchSummary(updated: 2, needAttention: 1))
    }

    @Test("a license block ends the run without installing or stranding rows")
    func licenseBlockStops() async {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let fixture = await makeFixture(authorize: { _ in
            attempts.withLock { $0 += 1 }
            return .failure(.trialExpired)
        })

        await fixture.session.updateAll(fixture.session.updatableRows, quitting: [])

        #expect(attempts.withLock { $0 } == 1)
        #expect(fixture.session.blockedReason == .trialExpired)
        #expect(fixture.installer.calls.isEmpty)
        #expect(fixture.session.installPhases.isEmpty)
        #expect(fixture.session.batch == nil)
        #expect(fixture.session.batchSummary == nil)
    }

    @Test("macOS refusing App Management ends the run after the first app")
    func appManagementDeniedStops() async {
        let fixture = await makeFixture()
        fixture.installer.failures[Self.ids[0]] = .appManagementDenied

        await fixture.session.updateAll(fixture.session.updatableRows, quitting: [])

        #expect(fixture.installer.calls.map(\.bundleID) == [Self.ids[0]])
        #expect(fixture.session.showsAppManagementHelp)
        #expect(fixture.session.installPhases.isEmpty)
    }

    /// Starts a run and waits until the first app is inside the installer.
    private func startHeldRun(_ fixture: Fixture, gate: Stubs.CheckGate) async -> Task<Void, Never> {
        fixture.installer.gate = gate
        let session = fixture.session
        let rows = session.updatableRows
        let run = Task { await session.updateAll(rows, quitting: []) }
        await Stubs.waitUntil { fixture.installer.running == 1 }
        return run
    }

    @Test("Stop finishes the current app and releases the waiting ones")
    func stopReleasesQueue() async {
        let fixture = await makeFixture()
        let gate = Stubs.CheckGate()
        let run = await startHeldRun(fixture, gate: gate)
        #expect(fixture.session.installPhases[Self.ids[1]] == .queued)
        #expect(fixture.session.batch?.waiting == 2)

        fixture.session.stopUpdateAll()

        #expect(fixture.session.installPhases[Self.ids[1]] == nil)
        #expect(fixture.session.batch?.total == 1)
        await gate.open()
        await run.value
        #expect(fixture.installer.calls.map(\.bundleID) == [Self.ids[0]])
        #expect(fixture.session.batchSummary == AppReleaseBatchSummary(updated: 1))
    }

    @Test("an app ignored while it waits is dropped from the run")
    func ignoreDropsQueuedRow() async {
        let fixture = await makeFixture()
        let gate = Stubs.CheckGate()
        let run = await startHeldRun(fixture, gate: gate)

        fixture.session.ignore(Self.ids[1])

        #expect(fixture.session.installPhases[Self.ids[1]] == nil)
        #expect(fixture.session.batch?.total == 2)
        await gate.open()
        await run.value
        #expect(fixture.installer.calls.map(\.bundleID) == [Self.ids[0], Self.ids[2]])
    }

    @Test("a check can't start during a run")
    func checkWaitsForRun() async {
        let fixture = await makeFixture()
        let gate = Stubs.CheckGate()
        let run = await startHeldRun(fixture, gate: gate)
        let checkedAt = fixture.session.lastChecked

        fixture.session.startCheck()
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(!fixture.session.isChecking)
        #expect(fixture.session.lastChecked == checkedAt)
        await gate.open()
        await run.value
    }

    @Test("an Update All confirmed while a check runs starts when the check ends")
    func confirmedDuringCheckRuns() async {
        let fixture = await makeFixture()
        let session = fixture.session
        let rows = session.updatableRows
        await fixture.hold.close()
        session.startCheck()
        await Stubs.waitUntil { await fixture.hold.waiting == 1 }

        let run = Task { await session.updateAll(rows, quitting: []) }
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(fixture.installer.calls.isEmpty)
        await fixture.hold.open()
        await run.value

        #expect(fixture.installer.calls.map(\.bundleID) == Self.ids)
    }

    @Test("a second Update All during a run does nothing")
    func secondRunIgnored() async {
        let fixture = await makeFixture()
        let gate = Stubs.CheckGate()
        let run = await startHeldRun(fixture, gate: gate)

        let session = fixture.session
        let second = Task { await session.updateAll(session.rows, quitting: []) }
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(fixture.session.batch?.total == 3)
        await gate.open()
        await second.value
        await run.value
        #expect(fixture.installer.calls.count == 3)
    }

    @Test("a row waiting on a new signer's approval is left out")
    func signerApprovalExcluded() async {
        let fixture = await makeFixture()
        let change = AppReleaseSignerChange(fromTeamID: "AAAAAAAAAA", toTeamID: "BBBBBBBBBB")
        fixture.installer.failures[Self.ids[0]] = .signerChanged(change)

        await fixture.session.updateAll(fixture.session.updatableRows, quitting: [])

        #expect(fixture.session.rowMessages[Self.ids[0]] == .signerChanged(change))
        #expect(!fixture.session.updatableRows.map(\.id).contains(Self.ids[0]))
    }

    @Test("the confirmation names the open apps and what stays closed")
    func requestWording() {
        let rows = Self.apps.map { AppReleaseRow(app: $0, status: updateStatus) }
        let one = AppReleaseUpdateAllRequest(rows: rows, openRows: [rows[0]])
        #expect(one.title == "Alpha is open")
        #expect(one.message.contains("Updating quits Alpha."))
        #expect(one.closedRows.map(\.id) == [Self.ids[1], Self.ids[2]])

        let many = (1 ... 7).map { AppReleaseRow(app: makeApp("App\($0)"), status: updateStatus) }
        let all = AppReleaseUpdateAllRequest(rows: many, openRows: many)
        #expect(all.title == "7 apps are open")
        for row in many { #expect(all.message.contains(row.app.name)) }
        #expect(all.closedRows.isEmpty)
    }
}
