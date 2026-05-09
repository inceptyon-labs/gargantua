import Foundation

/// Bounded result of a `/bin/launchctl` invocation captured for audit.
public struct LaunchctlResult: Sendable, Equatable {
    public let arguments: [String]
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(
        arguments: [String],
        exitCode: Int32,
        stdout: String,
        stderr: String
    ) {
        self.arguments = arguments
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

public protocol LaunchctlRunning: Sendable {
    /// Run `launchctl` with the given argv vector. The runner is expected to
    /// terminate the process before returning.
    func run(_ arguments: [String]) -> LaunchctlResult
}

/// Default runner that shells out to `/bin/launchctl`. Reads stdout/stderr to
/// EOF before returning so audit captures the full output.
public struct DefaultLaunchctlRunner: LaunchctlRunning {
    private let executableURL: URL

    public init(executableURL: URL = URL(fileURLWithPath: "/bin/launchctl")) {
        self.executableURL = executableURL
    }

    public func run(_ arguments: [String]) -> LaunchctlResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return LaunchctlResult(
                arguments: arguments,
                exitCode: -1,
                stdout: "",
                stderr: "Failed to launch launchctl: \(error.localizedDescription)"
            )
        }
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return LaunchctlResult(
            arguments: arguments,
            exitCode: process.terminationStatus,
            stdout: String(bytes: stdoutData, encoding: .utf8) ?? "",
            stderr: String(bytes: stderrData, encoding: .utf8) ?? ""
        )
    }
}
