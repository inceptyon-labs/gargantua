import Foundation
import os
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

        var installedVersion: AppReleaseVersion? { AppBundleFiles.bundleVersion(at: appURL) }

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
        trash: (any TrashMoving)? = nil,
        teamIDReader: @escaping @Sendable (URL) -> String? = { _ in "TEAM123456" }
    ) -> AppReleaseInstaller {
        AppReleaseInstaller(
            http: http,
            verifier: verifier,
            runner: runner,
            quitter: quitter,
            auditRecorder: audit,
            stagingRoot: sandbox.stagingRoot,
            brewLocator: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") },
            trash: trash ?? FakeTrashMover(trashDirectory: sandbox.trashDirectory),
            teamIDReader: teamIDReader
        )
    }

    private func install(
        _ installer: AppReleaseInstaller,
        sandbox: Sandbox,
        app: InstalledApp? = nil,
        strategy: AppReleaseInstallStrategy = .inPlace,
        quitIfRunning: Bool = true,
        authorization: DestructiveActionAuthorization = .unchecked(.appUpdater)
    ) async -> Result<AppReleaseInstallResult, AppReleaseInstallError> {
        await installer.install(
            app: app ?? sandbox.app,
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
        #expect(AppBundleFiles.bundleVersion(at: trashed) == AppReleaseVersion(short: "1.0", build: "100"))
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

    @Test("a fallback Trash failure in another language is still App Management")
    func fallbackTrashFailureLocalized() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [
            NSLocalizedDescriptionKey: "Vous n’avez pas l’autorisation d’enregistrer le fichier « Foo.app »."
        ])
        let other = NSError(domain: "NSOSStatusErrorDomain", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "L’opération n’a pas pu être effectuée."
        ])
        let trash = FallbackTrashMover(
            primary: FakeTrashMover(trashDirectory: sandbox.trashDirectory, error: denied),
            fallback: FakeTrashMover(trashDirectory: sandbox.trashDirectory, error: other)
        )

        let result = await install(makeInstaller(sandbox: sandbox, trash: trash), sandbox: sandbox)

        #expect(result == .failure(.appManagementDenied))
        #expect(sandbox.installedVersion == AppReleaseVersion(short: "1.0", build: "100"))
    }

    @Test("a fallback Trash failure is classified by code, not by English text")
    func fallbackTrashFailureByCode() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let error = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        let trash = FallbackTrashMover(
            primary: FakeTrashMover(trashDirectory: sandbox.trashDirectory, error: error),
            fallback: FakeTrashMover(trashDirectory: sandbox.trashDirectory, error: error)
        )

        let result = await install(makeInstaller(sandbox: sandbox, trash: trash), sandbox: sandbox)

        if case .failure(.swapFailed) = result {} else { Issue.record("expected swapFailed, got \(result)") }
        #expect(sandbox.installedVersion == AppReleaseVersion(short: "1.0", build: "100"))
    }

    @Test("a fallback Trash failure is App Management when only the fallback mover was refused")
    func fallbackTrashFailureDeniedByFallback() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let other = NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Etwas ist schiefgelaufen."])
        let trash = FallbackTrashMover(
            primary: FakeTrashMover(trashDirectory: sandbox.trashDirectory, error: other),
            fallback: FakeTrashMover(trashDirectory: sandbox.trashDirectory, error: POSIXError(.EPERM))
        )

        let result = await install(makeInstaller(sandbox: sandbox, trash: trash), sandbox: sandbox)

        #expect(result == .failure(.appManagementDenied))
        #expect(sandbox.installedVersion == AppReleaseVersion(short: "1.0", build: "100"))
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

    @Test("the download must be newer than the copy on disk now, not the one the check saw")
    func staleSnapshotRefusesDowngrade() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try Fixtures.writeBundle(at: sandbox.appURL, short: "2.2", build: "220")
        let snapshot = Fixtures.installedApp(at: sandbox.appURL, short: "2.0", build: "200")
        let audit = SpyUninstallAuditRecorder()
        let trash = FakeTrashMover(trashDirectory: sandbox.trashDirectory)

        let result = await install(
            makeInstaller(
                sandbox: sandbox,
                verifier: StubAppReleaseVerifier.staging(short: "2.1", build: "210"),
                audit: audit,
                trash: trash
            ),
            sandbox: sandbox,
            app: snapshot
        )

        #expect(result == .failure(.verification(.notNewer(staged: "2.1 (210)", installed: "2.2 (220)"))))
        #expect(sandbox.installedVersion == AppReleaseVersion(short: "2.2", build: "220"))
        #expect(trash.movedItems.isEmpty)
        #expect(audit.entries.isEmpty)
    }

    @Test("a newer version landing during the quit stops the swap and leaves it in place")
    func installedAppUpdatedBeforeSwap() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try Fixtures.writeBundle(at: sandbox.appURL, short: "1.9", build: "190")
        let appURL = sandbox.appURL
        // The app's own updater installs 2.1 as Gargantua quits it.
        let quitter = StubAppQuitter(running: true) {
            try? Fixtures.writeBundle(at: appURL, short: "2.1", build: "210")
        }
        let trash = FakeTrashMover(trashDirectory: sandbox.trashDirectory)
        let audit = SpyUninstallAuditRecorder()

        let result = await install(
            makeInstaller(sandbox: sandbox, quitter: quitter, audit: audit, trash: trash),
            sandbox: sandbox,
            app: Fixtures.installedApp(at: sandbox.appURL, short: "1.9", build: "190")
        )

        #expect(result == .failure(.installedAppChanged))
        #expect(sandbox.installedVersion == AppReleaseVersion(short: "2.1", build: "210"))
        #expect(trash.movedItems.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.trashDirectory.path).isEmpty)
        #expect(audit.entries.last?.files.isEmpty == true)
        #expect(quitter.relaunchedURLs == [sandbox.appURL])
    }

    @Test("a bundle swapped for a link during the quit stops the swap")
    func installedAppReplacedByLinkBeforeSwap() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let appURL = sandbox.appURL
        let elsewhere = sandbox.root.appendingPathComponent("Elsewhere/Foo.app", isDirectory: true)
        try Fixtures.writeBundle(at: elsewhere, short: "1.0", build: "100")
        let quitter = StubAppQuitter(running: true) {
            try? FileManager.default.removeItem(at: appURL)
            try? FileManager.default.createSymbolicLink(at: appURL, withDestinationURL: elsewhere)
        }
        let trash = FakeTrashMover(trashDirectory: sandbox.trashDirectory)

        let result = await install(makeInstaller(sandbox: sandbox, quitter: quitter, trash: trash), sandbox: sandbox)

        #expect(result == .failure(.installedAppChanged))
        #expect(trash.movedItems.isEmpty)
        #expect(AppBundleFiles.fileType(atPath: appURL.path) == S_IFLNK)
    }

    @Test("a different bundle at the app's path stops the install before anything downloads")
    func bundleIDChangedOnDisk() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try Fixtures.writeBundle(at: sandbox.appURL, bundleID: "com.example.Other", short: "1.0", build: "100")
        let http = RecordingPayloadHTTP()

        let result = await install(makeInstaller(sandbox: sandbox, http: http), sandbox: sandbox)

        #expect(result == .failure(.installedAppChanged))
        #expect(http.downloadCount == 0)
    }

    @Test("a stale staging folder is swept; a fresh one and a non-UUID entry stay")
    func sweepsStaleStaging() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let old = sandbox.stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fresh = sandbox.stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let other = sandbox.stagingRoot.appendingPathComponent("keep-me", isDirectory: true)
        for directory in [old, fresh, other] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: directory.appendingPathComponent("payload"))
        }
        let dayAndAHourAgo = Date().addingTimeInterval(-25 * 60 * 60)
        for directory in [old, other] {
            try FileManager.default.setAttributes([.modificationDate: dayAndAHourAgo], ofItemAtPath: directory.path)
        }

        AppReleaseInstaller.sweepStaleStaging(in: sandbox.stagingRoot)

        #expect(sandbox.stagingLeftovers.sorted() == [fresh.lastPathComponent, "keep-me"].sorted())
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
}

extension AppReleaseInstallerTests {
    @Test("download progress reaches the callback ending at the full size, before verifying and never after")
    func forwardsDownloadProgress() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let http = RecordingPayloadHTTP(reports: [(0, 100), (50, 100), (100, 100)])
        let phases = OSAllocatedUnfairLock<[AppReleaseInstallPhase]>(initialState: [])

        _ = await makeInstaller(sandbox: sandbox, http: http).install(
            app: sandbox.app,
            candidate: Fixtures.candidate(caskToken: "foo"),
            strategy: .inPlace,
            quitIfRunning: true,
            authorization: .unchecked(.appUpdater),
            progress: { phase in phases.withLock { $0.append(phase) } }
        )

        let seen = phases.withLock { $0 }
        // The stream keeps only the newest pending report, so a fast double may
        // coalesce the middle ones; the first and last must survive.
        let verifying = try #require(seen.firstIndex(of: .verifying))
        #expect(seen.first == .downloading(received: 0, expected: nil))
        #expect(seen[verifying - 1] == .downloading(received: 100, expected: 100))
        let downloadsAfter = seen[verifying...].filter { phase in
            if case .downloading = phase { return true }
            return false
        }
        #expect(downloadsAfter.isEmpty)
    }

    @Test("a download that fails after reporting progress fails the install with no later progress")
    func downloadFailsAfterProgress() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let http = RecordingPayloadHTTP(
            reports: [(10, 100), (50, 100)],
            failure: AppReleaseHTTPError.network("connection lost")
        )
        let phases = OSAllocatedUnfairLock<[AppReleaseInstallPhase]>(initialState: [])

        let result = await makeInstaller(sandbox: sandbox, http: http).install(
            app: sandbox.app,
            candidate: Fixtures.candidate(caskToken: "foo"),
            strategy: .inPlace,
            quitIfRunning: true,
            authorization: .unchecked(.appUpdater),
            progress: { phase in phases.withLock { $0.append(phase) } }
        )

        let seen = phases.withLock { $0 }
        #expect(result == .failure(.download("connection lost")))
        #expect(seen.last == .downloading(received: 50, expected: 100))
    }
}

extension AppReleaseInstallerTests {

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

    @Test("a brew upgrade that brings another team's signature succeeds with a warning")
    func brewUpgradeTeamChangeWarns() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let appURL = sandbox.appURL
        let runner = ScriptedBrewRunner { _ in
            try? Fixtures.writeBundle(at: appURL, short: "2.0", build: "200")
            return ProcessOutput(stdout: "", stderr: "", exitCode: 0)
        }
        let audit = SpyUninstallAuditRecorder()

        let result = await install(
            makeInstaller(sandbox: sandbox, runner: runner, audit: audit, teamIDReader: { _ in "OTHERTEAM1" }),
            sandbox: sandbox,
            strategy: .brewUpgrade(token: "foo")
        )

        let warning = "The new copy is signed by a different developer (OTHERTEAM1) than the copy it replaced (TEAM123456)."
        #expect(result == .success(AppReleaseInstallResult(
            installedVersion: AppReleaseVersion(short: "2.0", build: "200"),
            previousCopyInTrash: nil,
            relaunched: false,
            warning: warning
        )))
        #expect(audit.entries.map(\.status) == [.attempted, .completed])
        #expect(audit.entries.last?.command.hasSuffix("(warning: \(warning))") == true)
    }

    @Test("a tap-qualified cask token is refused before brew runs")
    func tapQualifiedTokenRefused() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runner = ScriptedBrewRunner { _ in ProcessOutput(stdout: "", stderr: "", exitCode: 0) }

        let result = await install(
            makeInstaller(sandbox: sandbox, runner: runner),
            sandbox: sandbox,
            strategy: .brewUpgrade(token: "user/tap/name")
        )

        #expect(result == .failure(.notInstallable))
        #expect(runner.recordedArguments.isEmpty)
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
