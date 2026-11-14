import AppKit
import Darwin
import Foundation
import GargantuaLicensing
import os

let appReleaseInstallLogger = Logger(subsystem: "com.gargantua.core", category: "AppReleaseInstaller")

/// Where an install is, for the row's progress label.
public enum AppReleaseInstallPhase: Sendable, Equatable {
    /// `expected` is nil when the server didn't declare a length.
    case downloading(received: Int64, expected: Int64?)
    case verifying
    case quitting
    case installing
    case relaunching
    case upgradingWithHomebrew
}

public enum AppReleaseInstallError: Error, Equatable, LocalizedError {
    case verification(AppReleaseVerificationFailure)
    /// The bundle at the app's path is gone, unreadable, or now carries a
    /// different bundle ID than the one checked.
    case installedAppChanged
    case download(String)
    case licenseAgreementRequired
    case stillRunning
    case appManagementDenied
    case differentVolume
    case swapFailed(String)
    case restoreFailed(trashPath: String)
    case brewUnavailable
    case brewFailed(String)
    case brewNoChange
    case notInstallable
    case wrongAuthorization

    public var errorDescription: String? {
        switch self {
        case .verification(let failure):
            "The update didn't pass verification, so nothing was changed. "
                + (failure.errorDescription ?? "")
        case .installedAppChanged:
            "The app changed on disk since Gargantua checked it, so nothing was changed. Check for updates again."
        case .download(let message):
            "The update couldn't be downloaded: \(message)"
        case .licenseAgreementRequired:
            "This update's disk image asks you to accept a license agreement. "
                + "Download it from the developer and install it by hand."
        case .stillRunning:
            "The app is still running. Quit it, then try again."
        case .appManagementDenied:
            "macOS didn't let Gargantua replace this app. Turn on Gargantua in System Settings > "
                + "Privacy & Security > App Management, then try again. Nothing was changed."
        case .differentVolume:
            "The app is on a different disk from Gargantua's download folder, so it can't be "
                + "replaced safely. Update it from the developer's site."
        case .swapFailed(let message):
            "The update couldn't be moved into place: \(message) The installed version was left as it was."
        case .restoreFailed(let trashPath):
            "The update couldn't be moved into place, and the previous version couldn't be put back. "
                + "Your previous copy is in the Trash at \(trashPath). Drag it back to Applications to restore it."
        case .brewUnavailable:
            "Homebrew isn't installed where Gargantua can find it."
        case .brewFailed(let message):
            "Homebrew couldn't upgrade the app: \(message)"
        case .brewNoChange:
            "Homebrew finished, but the app's version didn't change."
        case .notInstallable:
            "This update can't be installed from Gargantua. Open the developer's page instead."
        case .wrongAuthorization:
            "This install wasn't authorized for the App Updater."
        }
    }
}

public struct AppReleaseInstallResult: Sendable, Equatable {
    /// Read back from the bundle on disk after the install.
    public let installedVersion: AppReleaseVersion
    /// Where the replaced bundle went; nil for Homebrew upgrades.
    public let previousCopyInTrash: URL?
    public let relaunched: Bool
    /// Something the user should know about an install that did happen,
    /// e.g. a brew upgrade that brought a copy signed by another team.
    public let warning: String?

    public init(
        installedVersion: AppReleaseVersion,
        previousCopyInTrash: URL?,
        relaunched: Bool,
        warning: String? = nil
    ) {
        self.installedVersion = installedVersion
        self.previousCopyInTrash = previousCopyInTrash
        self.relaunched = relaunched
        self.warning = warning
    }
}

public protocol AppReleaseInstalling: Sendable {
    /// - Parameter quitIfRunning: The user's consent to quit the app. Without
    ///   it, a running app fails the install with `.stillRunning`.
    /// - Parameter authorization: Must be minted for `.appUpdater`.
    @MainActor
    // swiftlint:disable:next function_parameter_count
    func install(
        app: InstalledApp,
        candidate: AppReleaseCandidate,
        strategy: AppReleaseInstallStrategy,
        quitIfRunning: Bool,
        authorization: DestructiveActionAuthorization,
        progress: @escaping @MainActor @Sendable (AppReleaseInstallPhase) -> Void
    ) async -> Result<AppReleaseInstallResult, AppReleaseInstallError>
}

/// Quits and relaunches the app being updated. Never force-quits: an app that
/// doesn't quit within the timeout fails the install instead.
public protocol AppReleaseAppQuitting: Sendable {
    @MainActor func isRunning(bundleID: String) -> Bool
    @MainActor func quitGracefully(bundleID: String, timeout: TimeInterval) async -> Bool
    @MainActor func relaunch(at url: URL) async -> Bool
}

public struct WorkspaceAppReleaseQuitter: AppReleaseAppQuitting {
    public init() {}

    @MainActor
    public func isRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    /// Sends a normal quit and polls. The app may ask to save documents; the
    /// user answers that, and if it hasn't quit by the deadline it stays open.
    @MainActor
    public func quitGracefully(bundleID: String, timeout: TimeInterval) async -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        for app in apps {
            app.terminate()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !apps.allSatisfy(\.isTerminated) {
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                break
            }
        }
        return apps.allSatisfy(\.isTerminated)
    }

    @MainActor
    public func relaunch(at url: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }
}

/// Installs an available update: either downloads, verifies, and swaps the
/// bundle (old copy to the Trash), or runs `brew upgrade --cask` for apps
/// Homebrew manages.
public final class AppReleaseInstaller: AppReleaseInstalling {
    public static let quitTimeout: TimeInterval = 20
    static let brewTimeout: TimeInterval = 900
    static let brewCaptureBytes = 1_048_576
    static let auditTool = "app-updater"
    /// A staging folder this old was left by a crash, not an install in flight.
    static let staleStagingAge: TimeInterval = 24 * 60 * 60

    let http: any AppReleaseHTTPFetching
    let verifier: any AppReleaseVerifying
    let runner: any ProcessRunner
    let quitter: any AppReleaseAppQuitting
    let auditRecorder: any UninstallAuditRecording
    let stagingRoot: URL
    let brewLocator: @Sendable () -> URL?
    let trash: any TrashMoving
    /// Reads a bundle's Team ID from its signature, without validation.
    let teamIDReader: @Sendable (URL) -> String?

    /// Also starts a background sweep of staging folders a crash left behind.
    init(
        http: any AppReleaseHTTPFetching = DefaultAppReleaseHTTPClient(),
        verifier: any AppReleaseVerifying = AppReleaseVerifier(),
        runner: any ProcessRunner = DefaultProcessRunner(),
        quitter: any AppReleaseAppQuitting = WorkspaceAppReleaseQuitter(),
        auditRecorder: any UninstallAuditRecording = AuditWriter(),
        stagingRoot: URL = AppReleaseInstaller.defaultStagingRoot(),
        brewLocator: @escaping @Sendable () -> URL? = { DeveloperToolBinaryResolver().resolve(.homebrew) },
        trash: any TrashMoving = FallbackTrashMover(),
        teamIDReader: @escaping @Sendable (URL) -> String? = { StrictAppReleaseCodeSigner.teamIdentifier(ofBundle: $0) }
    ) {
        self.http = http
        self.verifier = verifier
        self.runner = runner
        self.quitter = quitter
        self.auditRecorder = auditRecorder
        self.stagingRoot = stagingRoot
        self.brewLocator = brewLocator
        self.trash = trash
        self.teamIDReader = teamIDReader
        Task.detached(priority: .utility) { Self.sweepStaleStaging(in: stagingRoot) }
    }

    /// `~/Library/Caches/com.gargantua.core/AppReleases/staging`, beside the
    /// Homebrew cask cache.
    public static func defaultStagingRoot() -> URL {
        HomebrewCaskIndex.defaultCacheDirectory().appendingPathComponent("staging", isDirectory: true)
    }

    @MainActor
    // swiftlint:disable:next function_parameter_count
    public func install(
        app: InstalledApp,
        candidate: AppReleaseCandidate,
        strategy: AppReleaseInstallStrategy,
        quitIfRunning: Bool,
        authorization: DestructiveActionAuthorization,
        progress: @escaping @MainActor @Sendable (AppReleaseInstallPhase) -> Void
    ) async -> Result<AppReleaseInstallResult, AppReleaseInstallError> {
        // The App Updater mints this token and spends it in the same flow, so
        // the surface can be asserted, as `UninstallExecutor` does.
        guard authorization.surface == .appUpdater else { return .failure(.wrongAuthorization) }

        do throws(AppReleaseInstallError) {
            switch strategy {
            case .openAppStore, .linkOnly:
                throw .notInstallable
            case .brewUpgrade(let token):
                return try await .success(upgradeWithHomebrew(
                    app: app,
                    candidate: candidate,
                    token: token,
                    quitIfRunning: quitIfRunning,
                    progress: progress
                ))
            case .inPlace:
                return try await .success(installInPlace(
                    app: app,
                    candidate: candidate,
                    quitIfRunning: quitIfRunning,
                    progress: progress
                ))
            }
        } catch {
            return .failure(error)
        }
    }

    // MARK: - In-place install

    /// Checks that cost nothing run first; the staging folder is removed
    /// however the install ends.
    @MainActor
    private func installInPlace(
        app snapshot: InstalledApp,
        candidate: AppReleaseCandidate,
        quitIfRunning: Bool,
        progress: @escaping @MainActor @Sendable (AppReleaseInstallPhase) -> Void
    ) async throws(AppReleaseInstallError) -> AppReleaseInstallResult {
        do throws(AppReleaseVerificationFailure) {
            try verifier.checkSourcePolicy(candidate, strategy: .inPlace)
        } catch {
            throw Self.installError(for: error)
        }
        // Replacing a symlink would leave its target behind and put a
        // second copy at the link's path.
        guard AppBundleFiles.fileType(atPath: snapshot.url.path) == S_IFDIR else { throw .notInstallable }
        let app = try Self.onDisk(snapshot)
        // Checked again after verification; this one only saves a download
        // that couldn't be installed.
        if !quitIfRunning, quitter.isRunning(bundleID: app.bundleID) { throw .stillRunning }

        let workDirectory: URL
        do {
            workDirectory = try Self.makeStagingDirectory(in: stagingRoot)
        } catch {
            throw .download("Couldn't create a download folder: \(error.localizedDescription)")
        }
        let result: Result<AppReleaseInstallResult, AppReleaseInstallError>
        do throws(AppReleaseInstallError) {
            result = try await .success(stageAndSwap(
                app: app,
                candidate: candidate,
                quitIfRunning: quitIfRunning,
                workDirectory: workDirectory,
                progress: progress
            ))
        } catch {
            result = .failure(error)
        }
        await Self.removeStagingDirectory(workDirectory)
        return try result.get()
    }

    /// The installed bundle as it is on disk now. The check's snapshot can be
    /// stale (the app may have updated itself since), and verifying against
    /// it would let an older download replace a newer install.
    static func onDisk(_ app: InstalledApp) throws(AppReleaseInstallError) -> InstalledApp {
        guard let plist = AppBundleFiles.infoPlist(ofBundle: app.url),
              plist["CFBundleIdentifier"] as? String == app.bundleID
        else { throw .installedAppChanged }
        let version = AppReleaseVersion(plist: plist)
        var current = app
        current.shortVersion = version.short
        current.buildVersion = version.build
        return current
    }

    /// The download, verification and quit can take minutes, and the app's
    /// own updater may land a newer version meanwhile (the quit can trigger
    /// it). Re-read right before the swap, so only a bundle that is still a
    /// real directory with the same ID and an older version is replaced.
    static func confirmStillReplaceable(
        _ app: InstalledApp,
        with stagedVersion: AppReleaseVersion
    ) throws(AppReleaseInstallError) {
        guard AppBundleFiles.fileType(atPath: app.url.path) == S_IFDIR else { throw .installedAppChanged }
        let current = try onDisk(app)
        guard stagedVersion.isNewer(than: current.version) else { throw .installedAppChanged }
    }

    /// Verification runs before the running app is touched; the installed
    /// copy is re-read once more right before the swap.
    @MainActor
    private func stageAndSwap(
        app: InstalledApp,
        candidate: AppReleaseCandidate,
        quitIfRunning: Bool,
        workDirectory: URL,
        progress: @escaping @MainActor @Sendable (AppReleaseInstallPhase) -> Void
    ) async throws(AppReleaseInstallError) -> AppReleaseInstallResult {
        guard Self.onSameVolume(workDirectory, app.url) else { throw .differentVolume }
        let staged = try await downloadAndVerify(app: app, candidate: candidate, workDirectory: workDirectory, progress: progress)

        let summary = "update \(app.bundleID) \(app.version) → \(staged.version)"
        let plan = AppReleaseAuditPlan(
            summary: summary,
            brewArguments: nil,
            unrecorded: .swapFailed("The audit log couldn't record the update, so nothing was changed."),
            phase: .installing
        )
        let (trashURL, relaunched) = try await runAudited(
            app: app,
            quitIfRunning: quitIfRunning,
            plan: plan,
            progress: progress
        ) { () async throws(AppReleaseStepFailure) -> (URL?, AppReleaseAuditLine) in
            do throws(AppReleaseInstallError) {
                try Self.confirmStillReplaceable(app, with: staged.version)
                let trashURL = try await swapBundle(at: app.url, with: staged.url)
                let files = [AuditFile(path: app.url.path, size: 0, trashPath: trashURL?.path)]
                return (trashURL, AppReleaseAuditLine(command: summary, files: files))
            } catch {
                throw AppReleaseStepFailure(error: error, line: Self.failedSwapLine(summary: summary, appURL: app.url, error: error))
            }
        }

        return AppReleaseInstallResult(
            installedVersion: AppBundleFiles.bundleVersion(at: app.url) ?? staged.version,
            previousCopyInTrash: trashURL,
            relaunched: relaunched
        )
    }

    @MainActor
    private func downloadAndVerify(
        app: InstalledApp,
        candidate: AppReleaseCandidate,
        workDirectory: URL,
        progress: @escaping @MainActor @Sendable (AppReleaseInstallPhase) -> Void
    ) async throws(AppReleaseInstallError) -> AppReleaseStagedBundle {
        guard let downloadURL = candidate.downloadURL else { throw .verification(.missingDownloadURL) }

        progress(.downloading(received: 0, expected: nil))
        let payload = workDirectory.appendingPathComponent("payload")
        // The stream keeps reports in order and lets every one land before
        // `.verifying`: it is drained once the download call returns.
        let (reports, report) = AsyncStream.makeStream(
            of: (Int64, Int64?).self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let forwarder = Task { @MainActor in
            for await (received, expected) in reports {
                progress(.downloading(received: received, expected: expected))
            }
        }
        do {
            _ = try await http.download(downloadURL, to: payload, maxBytes: AppReleaseVerifier.maxPayloadBytes) {
                report.yield(($0, $1))
            }
            report.finish()
            await forwarder.value
        } catch let error as AppReleaseHTTPError {
            report.finish()
            await forwarder.value
            throw Self.installError(for: error)
        } catch {
            report.finish()
            await forwarder.value
            throw .download(error.localizedDescription)
        }

        progress(.verifying)
        let verifier = verifier
        return try await Task.detached(priority: .userInitiated) {
            Result { () throws(AppReleaseVerificationFailure) -> AppReleaseStagedBundle in
                try verifier.verify(
                    payload: payload,
                    app: app,
                    candidate: candidate,
                    strategy: .inPlace,
                    workDirectory: workDirectory
                )
            }
        }.value.mapError(Self.installError(for:)).get()
    }

    static func installError(for failure: AppReleaseVerificationFailure) -> AppReleaseInstallError {
        failure == .licenseAgreementRequired ? .licenseAgreementRequired : .verification(failure)
    }

    static func installError(for error: AppReleaseHTTPError) -> AppReleaseInstallError {
        switch error {
        case .insecureURL(let url): .verification(.insecureDownloadURL(url))
        case .tooLarge(let limit): .verification(.downloadTooLarge(limit: limit))
        case .status, .network: .download(error.errorDescription ?? "Unknown download error.")
        }
    }
}
