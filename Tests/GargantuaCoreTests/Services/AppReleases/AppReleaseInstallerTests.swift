import Foundation
import GargantuaLicensing
import Testing
@testable import GargantuaCore

@MainActor
@Suite("AppReleaseInstaller")
struct AppReleaseInstallerTests {
    private typealias Fixtures = AppReleaseInstallFixtures

    /// A temp sandbox with an installed `Foo.app` 1.0, a staging root, and a
    /// stand-in Trash, all on one volume.
    private struct Sandbox {
        let root: URL
        let appURL: URL
        let stagingRoot: URL
        let trashDirectory: URL

        init() throws {
            root = try Fixtures.makeTemporaryDirectory()
            appURL = root.appendingPathComponent("Applications/Foo.app", isDirectory: true)
            stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
            trashDirectory = root.appendingPathComponent("Trash", isDirectory: true)
            try Fixtures.writeBundle(at: appURL, short: "1.0", build: "100")
            try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        }

        var app: InstalledApp { Fixtures.installedApp(at: appURL) }

        var installedVersion: AppReleaseVersion? { AppReleaseVerifier.bundleVersion(at: appURL) }

        var stagingLeftovers: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? []
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeInstaller(
        sandbox: Sandbox,
        http: RecordingPayloadHTTP = RecordingPayloadHTTP(),
        verifier: any AppReleaseVerifying = StubAppReleaseVerifier.staging(short: "2.0", build: "200"),
        runner: any ProcessRunner = ScriptedBrewRunner { _ in ProcessOutput(stdout: "", stderr: "", exitCode: 0) },
        quitter: StubAppQuitter = StubAppQuitter(),
        audit: SpyUninstallAuditRecorder = SpyUninstallAuditRecorder(),
        trash: FakeTrashMover? = nil
    ) -> AppReleaseInstaller {
        AppReleaseInstaller(
            http: http,
            verifier: verifier,
            runner: runner,
            quitter: quitter,
            auditRecorder: audit,
            stagingRoot: sandbox.stagingRoot,
            brewLocator: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") },
            trash: trash ?? FakeTrashMover(trashDirectory: sandbox.trashDirectory)
        )
    }

    private func install(
        _ installer: AppReleaseInstaller,
        sandbox: Sandbox,
        strategy: AppReleaseInstallStrategy = .inPlace,
        quitIfRunning: Bool = true,
        authorization: DestructiveActionAuthorization = .unchecked(.appUpdater)
    ) async -> Result<AppReleaseInstallResult, AppReleaseInstallError> {
        await installer.install(
            app: sandbox.app,
            candidate: Fixtures.candidate(caskToken: "foo"),
            strategy: strategy,
            quitIfRunning: quitIfRunning,
            authorization: authorization,
            progress: { _ in }
        )
    }

    @Test("a token minted for another surface is refused before anything runs")
    func wrongSurfaceRefused() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let http = RecordingPayloadHTTP()

        let result = await install(
            makeInstaller(sandbox: sandbox, http: http),
            sandbox: sandbox,
            authorization: .unchecked(.deepClean)
        )

        #expect(result == .failure(.wrongAuthorization))
        #expect(http.downloadCount == 0)
    }

    @Test("a verified update replaces the bundle and sends the old one to the Trash")
    func inPlaceInstallSwapsBundle() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let audit = SpyUninstallAuditRecorder()

        let result = await install(makeInstaller(sandbox: sandbox, audit: audit), sandbox: sandbox)

        let trashed = sandbox.trashDirectory.appendingPathComponent("Foo.app")
        #expect(result == .success(AppReleaseInstallResult(
            installedVersion: AppReleaseVersion(short: "2.0", build: "200"),
            previousCopyInTrash: trashed,
            relaunched: false
        )))
        #expect(sandbox.installedVersion == AppReleaseVersion(short: "2.0", build: "200"))
        #expect(AppReleaseVerifier.bundleVersion(at: trashed) == AppReleaseVersion(short: "1.0", build: "100"))
        #expect(audit.entries.map(\.status) == [.attempted, .completed])
        #expect(audit.entries.last?.files.first?.trashPath == trashed.path)
        #expect(sandbox.stagingLeftovers.isEmpty)
    }

    @Test("a Trash move refused with EPERM reports App Management and leaves the app alone")
    func trashPermissionDenied() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let trash = FakeTrashMover(trashDirectory: sandbox.trashDirectory, error: POSIXError(.EPERM))

        let result = await install(makeInstaller(sandbox: sandbox, trash: trash), sandbox: sandbox)

        #expect(result == .failure(.appManagementDenied))
        #expect(sandbox.installedVersion == AppReleaseVersion(short: "1.0", build: "100"))
        #expect(sandbox.stagingLeftovers.isEmpty)
    }

    @Test("when the new bundle can't be moved in, the old one comes back from the Trash")
    func failedMoveRestoresOldBundle() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let trash = FakeTrashMover(trashDirectory: sandbox.trashDirectory)

        let result = await install(
            makeInstaller(sandbox: sandbox, verifier: StubAppReleaseVerifier.stagingMissingBundle(), trash: trash),
            sandbox: sandbox
        )

        guard case .failure(.swapFailed) = result else {
            Issue.record("Expected swapFailed, got \(result)")
            return
        }
        #expect(trash.movedItems == [sandbox.appURL])
        #expect(sandbox.installedVersion == AppReleaseVersion(short: "1.0", build: "100"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.trashDirectory.path).isEmpty)
    }

    @Test("a running app is not quit without consent, and nothing changes")
    func runningAppWithoutConsent() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let quitter = StubAppQuitter(running: true)
        let audit = SpyUninstallAuditRecorder()
        let trash = FakeTrashMover(trashDirectory: sandbox.trashDirectory)

        let result = await install(
            makeInstaller(sandbox: sandbox, quitter: quitter, audit: audit, trash: trash),
            sandbox: sandbox,
            quitIfRunning: false
        )

        #expect(result == .failure(.stillRunning))
        #expect(quitter.quitRequests.isEmpty)
        #expect(trash.movedItems.isEmpty)
        #expect(audit.entries.isEmpty)
        #expect(sandbox.installedVersion == AppReleaseVersion(short: "1.0", build: "100"))
    }

    // MARK: - Homebrew

    @Test("brew upgrade that leaves a newer bundle on disk succeeds and is audited as a command")
    func brewUpgradeSucceeds() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let appURL = sandbox.appURL
        let runner = ScriptedBrewRunner { _ in
            try? Fixtures.writeBundle(at: appURL, short: "2.0", build: "200")
            return ProcessOutput(stdout: "==> Upgrading foo", stderr: "", exitCode: 0)
        }
        let audit = SpyUninstallAuditRecorder()

        let result = await install(
            makeInstaller(sandbox: sandbox, runner: runner, audit: audit),
            sandbox: sandbox,
            strategy: .brewUpgrade(token: "foo")
        )

        #expect(result == .success(AppReleaseInstallResult(
            installedVersion: AppReleaseVersion(short: "2.0", build: "200"),
            previousCopyInTrash: nil,
            relaunched: false
        )))
        #expect(runner.recordedArguments == [["upgrade", "--cask", "--greedy", "foo"]])
        #expect(audit.entries.map(\.status) == [.attempted, .completed])
        #expect(audit.entries.last?.kind == .command)
        #expect(audit.entries.last?.cleanupMethod == .toolNative)
        #expect(audit.entries.last?.commandArguments == ["upgrade", "--cask", "--greedy", "foo"])
    }

    @Test("a non-zero brew exit is reported with brew's own message")
    func brewUpgradeFails() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runner = ScriptedBrewRunner { _ in
            ProcessOutput(stdout: "", stderr: "Error: Download failed\n", exitCode: 1)
        }

        let result = await install(
            makeInstaller(sandbox: sandbox, runner: runner),
            sandbox: sandbox,
            strategy: .brewUpgrade(token: "foo")
        )

        #expect(result == .failure(.brewFailed("Error: Download failed")))
    }

    @Test("brew exiting cleanly without changing the bundle is not reported as an update")
    func brewUpgradeNoChange() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }

        let result = await install(
            makeInstaller(sandbox: sandbox),
            sandbox: sandbox,
            strategy: .brewUpgrade(token: "foo")
        )

        #expect(result == .failure(.brewNoChange))
    }
}
