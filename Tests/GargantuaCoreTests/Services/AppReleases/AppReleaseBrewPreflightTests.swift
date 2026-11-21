import Foundation
import GargantuaLicensing
import Testing
@testable import GargantuaCore

/// `brew upgrade` replaces a named cask from brew's own record of the
/// installed version, never the app on disk, so the installer reads the
/// download's version first.
@MainActor
@Suite("AppReleaseInstaller brew preflight")
struct AppReleaseBrewPreflightTests {
    private typealias Fixtures = AppReleaseInstallFixtures

    /// A sandbox with an installed `Foo.app` 1.0 (100) and a file standing in
    /// for brew's cached download.
    private struct Sandbox {
        let root: URL
        let appURL: URL
        let download: URL

        init() throws {
            root = try Fixtures.makeTemporaryDirectory()
            appURL = root.appendingPathComponent("Applications/Foo.app", isDirectory: true)
            download = root.appendingPathComponent("cache/foo-2.0.dmg")
            try Fixtures.writeBundle(at: appURL, short: "1.0", build: "100")
            try FileManager.default.createDirectory(at: download.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("dmg".utf8).write(to: download)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Answers brew the way it does when the cask fetches cleanly; `upgrade`
    /// leaves 2.0 on disk.
    private func brew(
        _ sandbox: Sandbox,
        caskVersion: String = "2.0,b7",
        fetchExit: Int32 = 0
    ) -> ScriptedBrewRunner {
        let appURL = sandbox.appURL
        let download = sandbox.download.path
        return ScriptedBrewRunner { arguments in
            switch arguments.first {
            case "fetch":
                return ProcessOutput(stdout: "", stderr: fetchExit == 0 ? "" : "Error: Download failed\n", exitCode: fetchExit)
            case "--cache":
                return ProcessOutput(stdout: download + "\n", stderr: "", exitCode: 0)
            case "info":
                return ProcessOutput(stdout: #"{"formulae":[],"casks":[{"token":"foo","version":"\#(caskVersion)"}]}"#, stderr: "", exitCode: 0)
            case "upgrade":
                try? Fixtures.writeBundle(at: appURL, short: "2.0", build: "200")
                return ProcessOutput(stdout: "", stderr: "", exitCode: 0)
            default:
                return ProcessOutput(stdout: "", stderr: "", exitCode: 0)
            }
        }
    }

    private func install(
        _ sandbox: Sandbox,
        runner: ScriptedBrewRunner,
        bundled: Result<AppReleaseVersion, AppReleaseVerificationFailure>,
        quitter: StubAppQuitter = StubAppQuitter(),
        quitIfRunning: Bool = true
    ) async -> Result<AppReleaseInstallResult, AppReleaseInstallError> {
        var verifier = StubAppReleaseVerifier.staging(short: "2.0", build: "200")
        verifier.bundled = bundled
        let installer = AppReleaseInstaller(
            verifier: verifier,
            runner: runner,
            quitter: quitter,
            auditRecorder: SpyUninstallAuditRecorder(),
            stagingRoot: sandbox.root.appendingPathComponent("staging", isDirectory: true),
            brewLocator: { URL(fileURLWithPath: "/opt/homebrew/bin/brew") },
            trash: FakeTrashMover(trashDirectory: sandbox.root.appendingPathComponent("Trash", isDirectory: true)),
            teamIDReader: { _ in "TEAM123456" }
        )
        return await installer.install(
            app: Fixtures.installedApp(at: sandbox.appURL),
            candidate: Fixtures.candidate(source: .homebrewCask, build: "", caskToken: "foo", caskVersion: "2.0,b7"),
            strategy: .brewUpgrade(token: "foo"),
            quitIfRunning: quitIfRunning,
            authorization: .unchecked(.appUpdater),
            progress: { _ in }
        )
    }

    private static let installed = AppReleaseVersion(short: "1.0", build: "100")
    private static let upgrade = ["upgrade", "--cask", "--greedy", "foo"]

    @Test("a newer download is fetched first, then upgraded")
    func newerDownloadUpgrades() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runner = brew(sandbox)

        let result = await install(sandbox, runner: runner, bundled: .success(AppReleaseVersion(short: "2.0", build: "200")))

        #expect(result == .success(AppReleaseInstallResult(
            installedVersion: AppReleaseVersion(short: "2.0", build: "200"),
            previousCopyInTrash: nil,
            relaunched: false
        )))
        #expect(runner.recordedArguments == [
            ["update-if-needed"], ["fetch", "--cask", "foo"], ["--cache", "--cask", "foo"], Self.upgrade,
        ])
    }

    @Test("an older or identical download of the offered release stops the upgrade as already current")
    func notNewerOfferedRelease() async throws {
        for staged in [AppReleaseVersion(short: "0.9", build: "90"), Self.installed] {
            let sandbox = try Sandbox()
            defer { sandbox.remove() }
            let runner = brew(sandbox)

            let result = await install(sandbox, runner: runner, bundled: .success(staged))

            #expect(result == .failure(.verification(.notNewer(staged: staged, installed: Self.installed))))
            #expect(result.failure?.versionAlreadyInstalled == "1.0 (100)")
            #expect(!runner.recordedArguments.contains(Self.upgrade))
            #expect(Fixtures.installedApp(at: sandbox.appURL).version == AppBundleFiles.bundleVersion(at: sandbox.appURL))
        }
    }

    @Test("an older download of another release than the row offered stops the upgrade without counting as current")
    func notNewerOtherRelease() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runner = brew(sandbox, caskVersion: "1.5,b3")
        let staged = AppReleaseVersion(short: "0.9", build: "90")

        let result = await install(sandbox, runner: runner, bundled: .success(staged))

        #expect(result == .failure(.brewDownloadNotNewer(staged: staged, installed: Self.installed)))
        #expect(result.failure?.versionAlreadyInstalled == nil)
        #expect(!runner.recordedArguments.contains(Self.upgrade))
    }

    @Test("a download that can't be read or ordered leaves the decision to brew")
    func unknownDownloadProceeds() async throws {
        let unordered = AppReleaseVersion(short: "1.0", build: "abc")
        for bundled in [Result<AppReleaseVersion, AppReleaseVerificationFailure>.failure(.appNotFound), .success(unordered)] {
            let sandbox = try Sandbox()
            defer { sandbox.remove() }
            let runner = brew(sandbox)

            let result = await install(sandbox, runner: runner, bundled: bundled)

            #expect(runner.recordedArguments.last == Self.upgrade)
            #expect((try? result.get())?.installedVersion == AppReleaseVersion(short: "2.0", build: "200"))
        }
    }

    @Test("a fetch that fails is reported and nothing is upgraded")
    func fetchFailure() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runner = brew(sandbox, fetchExit: 1)

        let result = await install(sandbox, runner: runner, bundled: .success(AppReleaseVersion(short: "2.0", build: "200")))

        #expect(result == .failure(.brewFailed("Error: Download failed")))
        #expect(!runner.recordedArguments.contains(Self.upgrade))
    }

    @Test("a running app without consent to quit fails before anything is fetched")
    func stillRunningBeforeFetch() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let runner = brew(sandbox)
        let quitter = StubAppQuitter()
        quitter.running = true

        let result = await install(
            sandbox, runner: runner, bundled: .success(Self.installed), quitter: quitter, quitIfRunning: false
        )

        #expect(result == .failure(.stillRunning))
        #expect(runner.recordedArguments.isEmpty)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
