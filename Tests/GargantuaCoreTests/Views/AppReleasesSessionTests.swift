import Foundation
import GargantuaLicensing
import Testing
@testable import GargantuaCore

@Suite("AppReleasesSession")
@MainActor
struct AppReleasesSessionTests {

    // MARK: - Stubs

    struct StubInventory: AppReleaseInventoryProviding {
        let apps: [InstalledApp]
        func installedApps() async -> [InstalledApp] { apps }
        func installedApp(at url: URL) async -> InstalledApp? { apps.first { $0.url == url } }
    }

    /// Hands out one scripted (delay, status) per check call, then the fallback.
    actor CheckerScript {
        private(set) var calls = 0
        private var steps: [(delay: Double, status: AppReleaseStatus)]
        private let fallback: AppReleaseStatus

        init(fallback: AppReleaseStatus, steps: [(delay: Double, status: AppReleaseStatus)] = []) {
            self.fallback = fallback
            self.steps = steps
        }

        func next() -> (delay: Double, status: AppReleaseStatus) {
            calls += 1
            return steps.isEmpty ? (0, fallback) : steps.removeFirst()
        }
    }

    struct ScriptedChecker: AppReleaseChecking {
        let script: CheckerScript
        func check(_ apps: [InstalledApp], preferences: AppReleasePreferences) async -> [AppReleaseRow] {
            let step = await script.next()
            if step.delay > 0 { try? await Task.sleep(for: .seconds(step.delay)) }
            return apps.map { AppReleaseRow(app: $0, status: step.status) }
        }
    }

    struct StubQuitter: AppReleaseAppQuitting {
        let running: Bool
        func isRunning(bundleID: String) -> Bool { running }
        func quitGracefully(bundleID: String, timeout: TimeInterval) async -> Bool { true }
        func relaunch(at url: URL) async -> Bool { true }
    }

    @MainActor
    final class StubInstaller: AppReleaseInstalling {
        private(set) var calls: [(bundleID: String, quitIfRunning: Bool)] = []

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
            return .success(AppReleaseInstallResult(
                installedVersion: candidate.version, previousCopyInTrash: nil, relaunched: false
            ))
        }
    }

    static let app = InstalledApp(
        bundleID: "com.example.tool",
        name: "Tool",
        url: URL(fileURLWithPath: "/Applications/Tool.app"),
        shortVersion: "1.0",
        teamID: "TEAM123456"
    )

    static let candidate = AppReleaseCandidate(
        source: .sparkle,
        version: AppReleaseVersion(short: "2.0", build: nil),
        downloadURL: URL(string: "https://example.com/Tool-2.0.zip")
    )

    static func makeDefaults() -> UserDefaults {
        let name = "AppReleasesSessionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    struct Fixture {
        let session: AppReleasesSession
        let installer: StubInstaller
        let defaults: UserDefaults
        let script: CheckerScript
    }

    static func makeFixture(
        authorize: @escaping @Sendable (DestructiveSurface) async -> DestructiveAuthorizationResult = { .success(.unchecked($0)) },
        isAppRunning: Bool = false,
        steps: [(delay: Double, status: AppReleaseStatus)] = [],
        now: @escaping () -> Date = Date.init,
        defaults: UserDefaults = makeDefaults()
    ) -> Fixture {
        let installer = StubInstaller()
        let script = CheckerScript(fallback: .available(candidate, .inPlace), steps: steps)
        let session = AppReleasesSession(
            inventory: StubInventory(apps: [app]),
            checker: ScriptedChecker(script: script),
            installer: installer,
            authorize: authorize,
            quitter: StubQuitter(running: isAppRunning),
            now: now,
            defaults: defaults
        )
        return Fixture(session: session, installer: installer, defaults: defaults, script: script)
    }

    // MARK: - Tests

    @Test("Ignoring an app marks its row ignored and persists")
    func ignorePersists() async {
        let fixture = Self.makeFixture()
        await fixture.session.check()
        #expect(fixture.session.availableCount == 1)

        fixture.session.ignore(Self.app.bundleID)

        #expect(fixture.session.rows.first?.status == .ignored)
        #expect(fixture.session.availableCount == 0)
        #expect(AppReleasePreferences.stored(in: fixture.defaults).ignoredBundleIDs == [Self.app.bundleID])
    }

    @Test("Skipping a version persists it and hides the update")
    func skipPersists() async {
        let fixture = Self.makeFixture()
        await fixture.session.check()

        fixture.session.skip(version: Self.candidate.displayVersion, for: Self.app.bundleID)

        #expect(fixture.session.rows.first?.status == .skippedVersion("2.0"))
        #expect(AppReleasePreferences.stored(in: fixture.defaults).skippedVersions[Self.app.bundleID] == "2.0")
    }

    @Test("A blocked license sets the reason and never calls the installer")
    func blockedLicenseSkipsInstaller() async throws {
        let fixture = Self.makeFixture(authorize: { _ in .failure(.trialExpired) })
        await fixture.session.check()
        let row = try #require(fixture.session.rows.first)

        await fixture.session.install(row, quitIfRunning: true)

        #expect(fixture.session.blockedReason == .trialExpired)
        #expect(fixture.installer.calls.isEmpty)
    }

    @Test("A running app is not installed without quit consent")
    func runningAppNeedsConsent() async throws {
        let fixture = Self.makeFixture(isAppRunning: true)
        await fixture.session.check()
        let row = try #require(fixture.session.rows.first)
        #expect(fixture.session.requiresQuitConsent(row))

        await fixture.session.install(row, quitIfRunning: false)
        #expect(fixture.installer.calls.isEmpty)

        await fixture.session.install(row, quitIfRunning: true)
        #expect(fixture.installer.calls.count == 1)
        #expect(fixture.installer.calls.first?.quitIfRunning == true)
    }

    @Test("The automatic check runs only when enabled and due")
    func autoCheckGating() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var clock = start
        let defaults = Self.makeDefaults()
        let fixture = Self.makeFixture(now: { clock }, defaults: defaults)

        await fixture.session.checkIfAutoDue()
        #expect(fixture.session.lastChecked == nil)

        AppReleasePreferences(autoCheckEnabled: true).store(in: defaults)
        await fixture.session.checkIfAutoDue()
        #expect(fixture.session.lastChecked == start)
        #expect(AppReleasePreferences.stored(in: defaults).lastAutoCheck == start)

        clock = start.addingTimeInterval(3_600)
        await fixture.session.checkIfAutoDue()
        #expect(fixture.session.lastChecked == start)

        clock = start.addingTimeInterval(25 * 3_600)
        await fixture.session.checkIfAutoDue()
        #expect(fixture.session.lastChecked == clock)
    }

    // MARK: - Concurrency

    /// Polls until the condition holds; the session's tasks are private.
    static func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<500 where !(await condition()) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Two concurrent installs of one row run the installer once")
    func concurrentInstallRunsOnce() async throws {
        let fixture = Self.makeFixture()
        await fixture.session.check()
        let row = try #require(fixture.session.rows.first)

        let session = fixture.session
        let first = Task { await session.install(row, quitIfRunning: false) }
        let second = Task { await session.install(row, quitIfRunning: false) }
        await first.value
        await second.value

        #expect(fixture.installer.calls.count == 1)
    }

    @Test("A blocked install frees the row to be tried again")
    func blockedInstallClearsInstalling() async throws {
        let fixture = Self.makeFixture(authorize: { _ in .failure(.trialExpired) })
        await fixture.session.check()
        let row = try #require(fixture.session.rows.first)

        await fixture.session.install(row, quitIfRunning: false)

        #expect(fixture.session.installPhases.isEmpty)
    }

    @Test("A check that read the old version doesn't overwrite a finished install")
    func checkDoesNotResurrectInstalledRow() async throws {
        let fixture = Self.makeFixture(steps: [
            (0, .available(Self.candidate, .inPlace)),
            (0.3, .available(Self.candidate, .inPlace)),
            (0, .upToDate(latest: Self.candidate)),
        ])
        await fixture.session.check()
        let row = try #require(fixture.session.rows.first)

        fixture.session.startCheck()
        await Self.waitUntil { await fixture.script.calls == 2 }
        await fixture.session.install(row, quitIfRunning: false)
        await Self.waitUntil { !fixture.session.isChecking }

        #expect(fixture.session.rows.first?.status == .upToDate(latest: Self.candidate))
        #expect(fixture.session.rows.count == 1)
    }

    @Test("A manual check during an automatic one does not start a second")
    func manualCheckJoinsAutomatic() async {
        let defaults = Self.makeDefaults()
        AppReleasePreferences(autoCheckEnabled: true).store(in: defaults)
        let fixture = Self.makeFixture(
            // Long enough that the manual Check lands while the automatic
            // one is still running, even on a loaded machine.
            steps: [(2, .available(Self.candidate, .inPlace))],
            defaults: defaults
        )

        let auto = Task { await fixture.session.checkIfAutoDue() }
        await Self.waitUntil { await fixture.script.calls == 1 }
        fixture.session.startCheck()
        await auto.value
        await Self.waitUntil { !fixture.session.isChecking }

        #expect(await fixture.script.calls == 1)
        #expect(fixture.session.lastChecked != nil)
    }

    @Test("Cancel stops an automatic check and leaves the list untouched")
    func cancelStopsAutomaticCheck() async {
        let defaults = Self.makeDefaults()
        AppReleasePreferences(autoCheckEnabled: true).store(in: defaults)
        let fixture = Self.makeFixture(
            // Long enough that only Cancel can end it; cancellation wakes the
            // sleep early, so a passing run stays fast.
            steps: [(30, .available(Self.candidate, .inPlace))],
            defaults: defaults
        )

        let auto = Task { await fixture.session.checkIfAutoDue() }
        await Self.waitUntil { await fixture.script.calls == 1 }
        fixture.session.cancelCheck()
        await auto.value

        #expect(fixture.session.phase == .idle)
        #expect(fixture.session.rows.isEmpty)
        #expect(AppReleasePreferences.stored(in: defaults).lastAutoCheck == nil)
    }

    @Test("An updated row stays in the Updates filter until the pane is left")
    func installedRowStaysVisible() async throws {
        let fixture = Self.makeFixture(steps: [
            (0, .available(Self.candidate, .inPlace)),
            (0, .upToDate(latest: Self.candidate)),
        ])
        await fixture.session.check()
        let row = try #require(fixture.session.rows.first)

        await fixture.session.install(row, quitIfRunning: false)

        #expect(fixture.session.visibleRows.map(\.id) == [Self.app.bundleID])
        #expect(fixture.session.rowMessages[Self.app.bundleID] == .installed("Updated to 2.0."))

        fixture.session.paneDidDisappear()
        #expect(fixture.session.visibleRows.isEmpty)
        #expect(fixture.session.rowMessages[Self.app.bundleID] == nil)
    }
}
