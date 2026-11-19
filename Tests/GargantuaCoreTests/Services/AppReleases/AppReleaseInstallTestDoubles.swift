import Foundation
import os
@testable import GargantuaCore

/// Fixtures shared by the verifier and installer tests.
enum AppReleaseInstallFixtures {
    static let bundleID = "com.example.Foo"

    /// A fresh directory under the temp dir. Callers remove it.
    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppReleaseInstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a minimal bundle: `Contents/Info.plist` with an identifier and
    /// versions.
    static func writeBundle(
        at url: URL,
        bundleID: String = bundleID,
        short: String,
        build: String,
        extra: [String: Any] = [:]
    ) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": short,
            "CFBundleVersion": build,
        ]
        plist.merge(extra) { _, new in new }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    static func installedApp(
        at url: URL,
        short: String = "1.0",
        build: String = "100",
        teamID: String? = "TEAM123456",
        sparklePublicEDKey: String? = nil
    ) -> InstalledApp {
        InstalledApp(
            bundleID: bundleID,
            name: "Foo",
            url: url,
            shortVersion: short,
            buildVersion: build,
            teamID: teamID,
            sparklePublicEDKey: sparklePublicEDKey
        )
    }

    static func candidate(
        source: AppReleaseSourceKind = .sparkle,
        short: String = "2.0",
        build: String = "200",
        expectedLength: Int64? = nil,
        edSignature: String? = nil,
        sha256: String? = nil,
        pinnedTeamID: String? = nil,
        isSparkleFeed: Bool? = nil,
        caskToken: String? = nil,
        downloadURL: String = "https://example.com/Foo.zip",
        downloadAgent: AppReleaseDownloadAgent = .updater
    ) -> AppReleaseCandidate {
        AppReleaseCandidate(
            source: source,
            version: AppReleaseVersion(short: short, build: build),
            downloadURL: URL(string: downloadURL),
            expectedLength: expectedLength,
            edSignature: edSignature,
            sha256: sha256,
            caskToken: caskToken,
            pinnedTeamID: pinnedTeamID,
            isSparkleFeed: isSparkleFeed,
            downloadAgent: downloadAgent
        )
    }
}

/// Writes a fixed payload and counts downloads.
final class RecordingPayloadHTTP: AppReleaseHTTPFetching {
    private let downloads = OSAllocatedUnfairLock(initialState: 0)
    private let recordedAgents = OSAllocatedUnfairLock<[AppReleaseDownloadAgent]>(initialState: [])
    /// (received, expected) pairs reported to the progress callback.
    let reports: [(Int64, Int64?)]

    /// Thrown after the scripted reports instead of writing the payload.
    let failure: (any Error)?

    init(reports: [(Int64, Int64?)] = [], failure: (any Error)? = nil) {
        self.reports = reports
        self.failure = failure
    }

    var downloadCount: Int { downloads.withLock { $0 } }
    var agents: [AppReleaseDownloadAgent] { recordedAgents.withLock { $0 } }

    func get(_ url: URL, etag _: String?) async throws -> AppReleaseHTTPResponse {
        throw AppReleaseHTTPError.network("get is not stubbed: \(url)")
    }

    func download(
        _: URL,
        to destination: URL,
        as agent: AppReleaseDownloadAgent,
        maxBytes _: Int64,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> Int64 {
        downloads.withLock { $0 += 1 }
        recordedAgents.withLock { $0.append(agent) }
        for (received, expected) in reports { progress(received, expected) }
        if let failure { throw failure }
        let data = Data("payload".utf8)
        try data.write(to: destination)
        return Int64(data.count)
    }
}

/// Skips real verification and stages whatever `stage` builds in the work
/// directory for the app it was handed.
struct StubAppReleaseVerifier: AppReleaseVerifying {
    let stage: @Sendable (URL, InstalledApp) -> Result<AppReleaseStagedBundle, AppReleaseVerificationFailure>

    func checkSourcePolicy(
        _: AppReleaseCandidate,
        strategy _: AppReleaseInstallStrategy
    ) throws(AppReleaseVerificationFailure) {}

    func verify(
        payload _: URL,
        app: InstalledApp,
        candidate _: AppReleaseCandidate,
        strategy _: AppReleaseInstallStrategy,
        workDirectory: URL
    ) throws(AppReleaseVerificationFailure) -> AppReleaseStagedBundle {
        try stage(workDirectory, app).get()
    }

    /// Stages a real bundle at `<work>/extracted/Foo.app` with the given
    /// version, then applies the real version check against the app it was
    /// handed.
    static func staging(short: String, build: String) -> StubAppReleaseVerifier {
        StubAppReleaseVerifier { workDirectory, app in
            let url = workDirectory.appendingPathComponent("extracted/Foo.app", isDirectory: true)
            do {
                try AppReleaseInstallFixtures.writeBundle(at: url, short: short, build: build)
            } catch {
                return .failure(.extractionFailed(error.localizedDescription))
            }
            return Result { () throws(AppReleaseVerificationFailure) in
                let version = try AppReleaseVerifier.checkVersion(
                    of: url,
                    installed: app,
                    hostOSVersion: ProcessInfo.processInfo.operatingSystemVersion
                )
                return AppReleaseStagedBundle(url: url, version: version)
            }
        }
    }

    /// Reports a staged bundle that doesn't exist, so the swap's move fails.
    static func stagingMissingBundle() -> StubAppReleaseVerifier {
        StubAppReleaseVerifier { workDirectory, _ in
            .success(AppReleaseStagedBundle(
                url: workDirectory.appendingPathComponent("extracted/Missing.app", isDirectory: true),
                version: AppReleaseVersion(short: "2.0", build: "200")
            ))
        }
    }
}

/// Moves items into a test-owned directory, or throws `error`.
@MainActor
final class FakeTrashMover: TrashMoving {
    let trashDirectory: URL
    var error: (any Error)?
    private(set) var movedItems: [URL] = []

    init(trashDirectory: URL, error: (any Error)? = nil) {
        self.trashDirectory = trashDirectory
        self.error = error
    }

    func moveToTrash(_ url: URL) async throws -> URL? {
        if let error { throw error }
        let destination = trashDirectory.appendingPathComponent(url.lastPathComponent, isDirectory: true)
        try FileManager.default.moveItem(at: url, to: destination)
        movedItems.append(url)
        return destination
    }
}

@MainActor
final class StubAppQuitter: AppReleaseAppQuitting {
    var running: Bool
    /// Runs when the app quits, standing in for what the app does on its way out.
    var onQuit: (@MainActor () -> Void)?
    private(set) var quitRequests: [String] = []
    private(set) var relaunchedURLs: [URL] = []

    init(running: Bool = false, onQuit: (@MainActor () -> Void)? = nil) {
        self.running = running
        self.onQuit = onQuit
    }

    func isRunning(bundleID _: String) -> Bool {
        running
    }

    func quitGracefully(bundleID: String, timeout _: TimeInterval) async -> Bool {
        quitRequests.append(bundleID)
        running = false
        onQuit?()
        return true
    }

    func relaunch(at url: URL) async -> Bool {
        relaunchedURLs.append(url)
        return true
    }
}

/// Answers every run with `handler` and records the arguments.
final class ScriptedBrewRunner: ProcessRunner {
    private let handler: @Sendable ([String]) -> ProcessOutput
    private let calls = OSAllocatedUnfairLock<[[String]]>(initialState: [])

    init(handler: @escaping @Sendable ([String]) -> ProcessOutput) {
        self.handler = handler
    }

    var recordedArguments: [[String]] { calls.withLock { $0 } }

    func run(executable _: URL, arguments: [String]) throws -> ProcessOutput {
        calls.withLock { $0.append(arguments) }
        return handler(arguments)
    }
}

/// Reports a fixed signature whose certificate was issued only to
/// `certifiedTeams`.
struct StubCodeSigner: AppReleaseCodeSigning {
    var report = AppReleaseSignatureReport(isValid: true, teamID: "TEAM123456", isDeveloperID: true)
    var certifiedTeams: Set<String> = ["TEAM123456"]

    func assess(bundleURL _: URL, requiredTeams: [String]) -> AppReleaseSignatureReport {
        AppReleaseSignatureReport(
            isValid: report.isValid,
            teamID: report.teamID,
            isDeveloperID: report.isDeveloperID,
            failure: report.failure,
            uncertifiedTeam: requiredTeams.first { !certifiedTeams.contains($0) }
        )
    }
}

struct AcceptingGatekeeper: AppReleaseGatekeeperAssessing {
    func assess(bundleURL _: URL) -> AppReleaseGatekeeperVerdict {
        AppReleaseGatekeeperVerdict(accepted: true, source: "Notarized Developer ID", detail: "accepted")
    }
}
