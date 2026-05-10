import AppKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "DockerDaemonControl")

/// User-initiated start/stop controls for the Docker daemon (Docker Desktop).
///
/// `start()` prefers Docker Desktop's own CLI (`docker desktop start/restart`)
/// and falls back to opening the app bundle. `stop()` sends an AppleScript quit
/// to the running app, the same as choosing Quit from the menu bar.
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

    enum DesktopStatus: Sendable, Equatable {
        case running
        case starting
        case stopped
        case unknown
    }

    private let resolver: DeveloperToolBinaryResolver
    private let runner: any ProcessRunner
    private let appPaths: [String]
    private let appOpener: @Sendable (URL) -> Bool
    /// Time budget for `pollUntilRunning` after a `start()` call.
    private let pollTimeout: TimeInterval
    /// Delay between status checks during polling.
    private let pollInterval: TimeInterval

    public init(
        resolver: DeveloperToolBinaryResolver = DeveloperToolBinaryResolver(),
        runner: any ProcessRunner = DefaultProcessRunner(),
        appPaths: [String] = ["/Applications/Docker.app", "/Applications/Docker Desktop.app"],
        appOpener: (@Sendable (URL) -> Bool)? = nil,
        pollTimeout: TimeInterval = 90,
        pollInterval: TimeInterval = 2
    ) {
        self.resolver = resolver
        self.runner = runner
        self.appPaths = appPaths
        self.appOpener = appOpener ?? Self.defaultAppOpener
        self.pollTimeout = pollTimeout
        self.pollInterval = pollInterval
    }

    /// Ask Docker Desktop to start. Returns true if a launch/restart was
    /// dispatched; the daemon may still take several seconds to come up — call
    /// `pollUntilRunning` to wait for it.
    @discardableResult
    public func start() -> Bool {
        if let executable = resolver.resolve(.docker) {
            switch desktopStatus(executable: executable) {
            case .running:
                // Desktop can report "running" while the daemon socket is
                // wedged. Opening the app again is a no-op; a Desktop restart
                // is the useful recovery nudge.
                if runDockerDesktopCommand(executable: executable, command: "restart") {
                    return true
                }
            case .starting:
                return true
            case .stopped, .unknown:
                if runDockerDesktopCommand(executable: executable, command: "start") {
                    return true
                }
            }
        }

        return openDockerApp()
    }

    func desktopStatus(executable: URL) -> DesktopStatus {
        do {
            let output = try runner.run(
                executable: executable,
                arguments: ["desktop", "status"],
                timeout: 5,
                maxCapturedBytes: 4096
            )
            guard output.exitCode == 0 else { return .unknown }
            return Self.parseDesktopStatus(output.stdout)
        } catch {
            return .unknown
        }
    }

    static func parseDesktopStatus(_ stdout: String) -> DesktopStatus {
        for line in stdout.split(whereSeparator: \.isNewline) {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 2, columns[0].lowercased() == "status" else { continue }
            switch columns[1].lowercased() {
            case "running":
                return .running
            case "starting":
                return .starting
            case "stopped", "stopping", "not-running", "notrunning":
                return .stopped
            default:
                return .unknown
            }
        }
        return .unknown
    }

    private func runDockerDesktopCommand(executable: URL, command: String) -> Bool {
        do {
            let output = try runner.run(
                executable: executable,
                arguments: ["desktop", command, "--detach", "--timeout", "10"],
                timeout: 15,
                maxCapturedBytes: 4096
            )
            if output.exitCode == 0 { return true }
            logger.error("docker desktop \(command, privacy: .public) failed: \(output.stderr, privacy: .public)")
            return false
        } catch {
            logger.error("docker desktop \(command, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func openDockerApp() -> Bool {
        guard let appPath = appPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            logger.error("Docker.app not found in expected application paths")
            return false
        }
        let appURL = URL(fileURLWithPath: appPath)
        return appOpener(appURL)
    }

    private static let defaultAppOpener: @Sendable (URL) -> Bool = { appURL in
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
