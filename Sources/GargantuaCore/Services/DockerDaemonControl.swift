import AppKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "DockerDaemonControl")

/// User-initiated start/stop controls for the Docker daemon (Docker Desktop).
///
/// `start()` opens `/Applications/Docker.app` via `NSWorkspace` — the standard
/// way users launch Docker Desktop. `stop()` sends an AppleScript quit to the
/// running app, the same as choosing Quit from the menu bar.
///
/// Neither action goes through the cleanup-confirmation modal: starting an
/// app is harmless, and quitting Docker is the normal shutdown the user would
/// do themselves. Both call sites surface the action explicitly so there's no
/// hidden behavior.
public struct DockerDaemonControl: Sendable {
    public enum Status: Sendable, Equatable {
        case running
        case stopped
        case unknown
    }

    private let resolver: DeveloperToolBinaryResolver
    private let runner: any ProcessRunner
    /// Time budget for `pollUntilRunning` after a `start()` call.
    private let pollTimeout: TimeInterval
    /// Delay between status checks during polling.
    private let pollInterval: TimeInterval

    public init(
        resolver: DeveloperToolBinaryResolver = DeveloperToolBinaryResolver(),
        runner: any ProcessRunner = DefaultProcessRunner(),
        pollTimeout: TimeInterval = 90,
        pollInterval: TimeInterval = 2
    ) {
        self.resolver = resolver
        self.runner = runner
        self.pollTimeout = pollTimeout
        self.pollInterval = pollInterval
    }

    /// Open Docker Desktop. Returns true if the launch was dispatched; the
    /// daemon may still take several seconds to come up — call
    /// `pollUntilRunning` to wait for it.
    @discardableResult
    public func start() -> Bool {
        let appURL = URL(fileURLWithPath: "/Applications/Docker.app")
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            logger.error("Docker.app not found at \(appURL.path, privacy: .public)")
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        return true
    }

    /// Quit Docker Desktop. Uses the same path the user would take from the
    /// menu bar so any in-flight container shutdown handlers run.
    public func stop() {
        let script = "tell application \"Docker\" to quit"
        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            logger.error("Docker quit AppleScript failed: \(error.description, privacy: .public)")
        }
    }

    /// Probe the daemon by running `docker info`. Exit 0 means the daemon
    /// answered. Anything else (including the missing-binary case) is
    /// reported as `.stopped` / `.unknown` so callers can render a CTA.
    public func currentStatus() -> Status {
        guard let executable = resolver.resolve(.docker) else { return .unknown }
        do {
            let output = try runner.run(
                executable: executable,
                arguments: ["info", "--format", "{{.ServerVersion}}"],
                timeout: 4,
                maxCapturedBytes: 4096
            )
            if output.exitCode == 0 { return .running }
            if DeveloperToolPreviewError.isDockerDaemonNotRunning(stderr: output.stderr) {
                return .stopped
            }
            return .unknown
        } catch {
            return .unknown
        }
    }

    /// Poll the daemon every `pollInterval` seconds until it reports running
    /// or `pollTimeout` elapses. Returns true on success, false on timeout
    /// or cancellation.
    public func pollUntilRunning() async -> Bool {
        let deadline = Date().addingTimeInterval(pollTimeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if currentStatus() == .running { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return false
    }

    /// Poll until the daemon reports stopped (or `pollTimeout` elapses).
    /// Used after `stop()` so the UI can flip to the daemon-stopped state
    /// once Docker has actually shut down rather than guessing.
    public func pollUntilStopped() async -> Bool {
        let deadline = Date().addingTimeInterval(pollTimeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if currentStatus() == .stopped { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return false
    }
}
