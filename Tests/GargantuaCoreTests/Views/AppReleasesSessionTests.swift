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

    struct StubChecker: AppReleaseChecking {
        let status: AppReleaseStatus
        func check(_ apps: [InstalledApp], preferences: AppReleasePreferences) async -> [AppReleaseRow] {
            apps.map { app in
                AppReleaseRow(
                    app: app,
                    status: preferences.ignoredBundleIDs.contains(app.bundleID) ? .ignored : status
                )
            }
        }
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
    }

    static func makeFixture(
        authorize: @escaping @Sendable (DestructiveSurface) async -> DestructiveAuthorizationResult = { .success(.unchecked($0)) },
        isAppRunning: @escaping @MainActor (String) -> Bool = { _ in false },
        now: @escaping () -> Date = Date.init,
        defaults: UserDefaults = makeDefaults()
    ) -> Fixture {
        let installer = StubInstaller()
        let session = AppReleasesSession(
            inventory: StubInventory(apps: [app]),
            checker: StubChecker(status: .available(candidate, .inPlace)),
            installer: installer,
            authorize: authorize,
            isAppRunning: isAppRunning,
            now: now,
            defaults: defaults
        )
        return Fixture(session: session, installer: installer, defaults: defaults)
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
        let fixture = Self.makeFixture(isAppRunning: { _ in true })
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
}
