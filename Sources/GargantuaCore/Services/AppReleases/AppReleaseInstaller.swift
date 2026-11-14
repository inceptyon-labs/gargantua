import AppKit
import Foundation
import GargantuaLicensing
import os

let appReleaseInstallLogger = Logger(subsystem: "com.gargantua.core", category: "AppReleaseInstaller")

/// Where an install is, for the row's progress label.
public enum AppReleaseInstallPhase: Sendable, Equatable {
    case downloading
    case verifying
    case quitting
    case installing
    case relaunching
    case upgradingWithHomebrew
}

public enum AppReleaseInstallError: Error, Equatable, LocalizedError {
    case verification(AppReleaseVerificationFailure)
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

    public init(installedVersion: AppReleaseVersion, previousCopyInTrash: URL?, relaunched: Bool) {
        self.installedVersion = installedVersion
        self.previousCopyInTrash = previousCopyInTrash
        self.relaunched = relaunched
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

    let http: any AppReleaseHTTPFetching
    let verifier: any AppReleaseVerifying
    let runner: any ProcessRunner
    let quitter: any AppReleaseAppQuitting
    let auditRecorder: any UninstallAuditRecording
    let stagingRoot: URL
    let brewLocator: @Sendable () -> URL?
    let trash: any TrashMoving

    public convenience init(
        http: any AppReleaseHTTPFetching = DefaultAppReleaseHTTPClient(),
        signer: any AppReleaseCodeSigning = StrictAppReleaseCodeSigner(),
        gatekeeper: any AppReleaseGatekeeperAssessing = SpctlAppReleaseGatekeeper(),
        runner: any ProcessRunner = DefaultProcessRunner(),
        quitter: any AppReleaseAppQuitting = WorkspaceAppReleaseQuitter(),
        auditRecorder: any UninstallAuditRecording = AuditWriter(),
        stagingRoot: URL = AppReleaseInstaller.defaultStagingRoot(),
        hostOSVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        brewLocator: @escaping @Sendable () -> URL? = { DeveloperToolBinaryResolver().resolve(.homebrew) }
    ) {
        self.init(
            http: http,
            verifier: AppReleaseVerifier(
                signer: signer,
                gatekeeper: gatekeeper,
                runner: runner,
                hostOSVersion: hostOSVersion
            ),
            runner: runner,
            quitter: quitter,
            auditRecorder: auditRecorder,
            stagingRoot: stagingRoot,
            brewLocator: brewLocator
        )
    }

    init(
        http: any AppReleaseHTTPFetching,
        verifier: any AppReleaseVerifying,
        runner: any ProcessRunner,
        quitter: any AppReleaseAppQuitting,
        auditRecorder: any UninstallAuditRecording,
        stagingRoot: URL,
        brewLocator: @escaping @Sendable () -> URL?,
        trash: any TrashMoving = FallbackTrashMover()
    ) {
        self.http = http
        self.verifier = verifier
        self.runner = runner
        self.quitter = quitter
        self.auditRecorder = auditRecorder
        self.stagingRoot = stagingRoot
        self.brewLocator = brewLocator
        self.trash = trash
    }

    /// `~/Library/Caches/com.gargantua.core/AppReleases/staging`.
    public static func defaultStagingRoot() -> URL {
        let caches = (try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return caches.appendingPathComponent("com.gargantua.core/AppReleases/staging", isDirectory: true)
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

        switch strategy {
        case .openAppStore, .linkOnly:
            return .failure(.notInstallable)
        case .brewUpgrade(let token):
            return await upgradeWithHomebrew(
                app: app,
                candidate: candidate,
                token: token,
                quitIfRunning: quitIfRunning,
                progress: progress
            )
        case .inPlace:
            do throws(AppReleaseVerificationFailure) {
                try verifier.checkSourcePolicy(candidate, strategy: strategy)
            } catch {
                return .failure(Self.installError(for: error))
            }
            // Replacing a symlink would leave its target behind and put a
            // second copy at the link's path.
            guard AppReleaseVerifier.fileType(atPath: app.url.path) == S_IFDIR else { return .failure(.notInstallable) }
            // Checked again after verification; this one only saves a download
            // that couldn't be installed.
            if !quitIfRunning, quitter.isRunning(bundleID: app.bundleID) { return .failure(.stillRunning) }
            let workDirectory: URL
            do {
                workDirectory = try Self.makeStagingDirectory(in: stagingRoot)
            } catch {
                return .failure(.download("Couldn't create a download folder: \(error.localizedDescription)"))
            }
            let result = await installInPlace(
                app: app,
                candidate: candidate,
                quitIfRunning: quitIfRunning,
                workDirectory: workDirectory,
                progress: progress
            )
            await Self.removeStagingDirectory(workDirectory)
            return result
        }
    }

    // MARK: - In-place install

    @MainActor
    private func installInPlace(
        app: InstalledApp,
        candidate: AppReleaseCandidate,
        quitIfRunning: Bool,
        workDirectory: URL,
        progress: @escaping @MainActor @Sendable (AppReleaseInstallPhase) -> Void
    ) async -> Result<AppReleaseInstallResult, AppReleaseInstallError> {
        guard Self.onSameVolume(workDirectory, app.url) else { return .failure(.differentVolume) }

        // Every check runs before the running app is touched.
        let staged: AppReleaseStagedBundle
        switch await downloadAndVerify(app: app, candidate: candidate, workDirectory: workDirectory, progress: progress) {
        case .success(let bundle): staged = bundle
        case .failure(let error): return .failure(error)
        }

        let wasRunning: Bool
        switch await quitIfNeeded(bundleID: app.bundleID, consent: quitIfRunning, progress: progress) {
        case .success(let quit): wasRunning = quit
        case .failure(let error): return .failure(error)
        }

        let auditID = UUID()
        let summary = "update \(app.bundleID) \(app.version) → \(staged.version)"
        do {
            try auditRecorder.write(Self.pathAuditEntry(
                id: auditID,
                command: summary,
                files: [AuditFile(path: app.url.path, size: 0)],
                status: .attempted
            ))
        } catch {
            appReleaseInstallLogger.error("App update intent audit failed: \(error.localizedDescription, privacy: .public)")
            await relaunchIfNeeded(app.url, wasRunning: wasRunning)
            return .failure(.swapFailed("The audit log couldn't record the update, so nothing was changed."))
        }

        progress(.installing)
        let trashURL: URL?
        switch await swapBundle(at: app.url, with: staged.url) {
        case .success(let url):
            trashURL = url
        case .failure(let error):
            recordFailedSwap(id: auditID, appURL: app.url, summary: summary, error: error)
            await relaunchIfNeeded(app.url, wasRunning: wasRunning)
            return .failure(error)
        }

        do {
            try auditRecorder.write(Self.pathAuditEntry(
                id: auditID,
                command: summary,
                files: [AuditFile(path: app.url.path, size: 0, trashPath: trashURL?.path)],
                status: .completed
            ))
        } catch {
            appReleaseInstallLogger.error("App update audit failed after swap: \(error.localizedDescription, privacy: .public)")
        }

        let installedVersion = AppReleaseVerifier.bundleVersion(at: app.url) ?? staged.version
        let relaunched = await relaunchAfterSuccess(app.url, wasRunning: wasRunning, progress: progress)
        return .success(AppReleaseInstallResult(
            installedVersion: installedVersion,
            previousCopyInTrash: trashURL,
            relaunched: relaunched
        ))
    }

    @MainActor
    private func downloadAndVerify(
        app: InstalledApp,
        candidate: AppReleaseCandidate,
        workDirectory: URL,
        progress: @escaping @MainActor @Sendable (AppReleaseInstallPhase) -> Void
    ) async -> Result<AppReleaseStagedBundle, AppReleaseInstallError> {
        guard let downloadURL = candidate.downloadURL else { return .failure(.verification(.missingDownloadURL)) }

        progress(.downloading)
        let payload = workDirectory.appendingPathComponent("payload")
        do {
            _ = try await http.download(downloadURL, to: payload, maxBytes: AppReleaseVerifier.maxPayloadBytes)
        } catch let error as AppReleaseHTTPError {
            return .failure(Self.installError(for: error))
        } catch {
            return .failure(.download(error.localizedDescription))
        }

        progress(.verifying)
        let verifier = verifier
        return await Task.detached(priority: .userInitiated) {
            () -> Result<AppReleaseStagedBundle, AppReleaseInstallError> in
            do throws(AppReleaseVerificationFailure) {
                return try .success(verifier.verify(
                    payload: payload,
                    app: app,
                    candidate: candidate,
                    strategy: .inPlace,
                    workDirectory: workDirectory
                ))
            } catch {
                return .failure(Self.installError(for: error))
            }
        }.value
    }

    // MARK: - Shared steps

    /// Returns whether the app was running and has now quit.
    @MainActor
    func quitIfNeeded(
        bundleID: String,
        consent: Bool,
        progress: @escaping @MainActor @Sendable (AppReleaseInstallPhase) -> Void
    ) async -> Result<Bool, AppReleaseInstallError> {
        guard quitter.isRunning(bundleID: bundleID) else { return .success(false) }
        guard consent else { return .failure(.stillRunning) }
        progress(.quitting)
        guard await quitter.quitGracefully(bundleID: bundleID, timeout: Self.quitTimeout) else {
            return .failure(.stillRunning)
        }
        return .success(true)
    }

    @MainActor
    func relaunchAfterSuccess(
        _ url: URL,
        wasRunning: Bool,
        progress: @escaping @MainActor @Sendable (AppReleaseInstallPhase) -> Void
    ) async -> Bool {
        guard wasRunning else { return false }
        progress(.relaunching)
        return await quitter.relaunch(at: url)
    }

    /// Reopens an app this flow quit when the install stopped short, as long
    /// as a bundle is still at its path.
    @MainActor
    func relaunchIfNeeded(_ url: URL, wasRunning: Bool) async {
        guard wasRunning, AppReleaseVerifier.fileType(atPath: url.path) != nil else { return }
        _ = await quitter.relaunch(at: url)
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
