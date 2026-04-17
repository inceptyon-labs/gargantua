import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "MoleRunner")

/// Result of executing a Mole CLI command.
public struct MoleRunResult: Sendable {
    /// Raw stdout data from the process.
    public let stdout: Data
    /// Raw stderr data from the process.
    public let stderr: Data
    /// Process exit code (0 = success).
    public let exitCode: Int32
    /// Wall-clock duration of the execution.
    public let duration: TimeInterval

    /// Stdout decoded as UTF-8 string.
    public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    /// Stderr decoded as UTF-8 string.
    public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }

    /// Whether the command completed with exit code 0.
    public var succeeded: Bool {
        exitCode == 0
    }
}

/// Errors that can occur when running the Mole CLI.
public enum MoleError: Error, LocalizedError, Sendable {
    /// The bundled `mo` binary was not found in the app bundle.
    case binaryNotFound(searchedPath: String)
    /// The command timed out after the configured duration.
    case timeout(command: String, seconds: TimeInterval)
    /// The process crashed (non-zero exit with signal-like codes).
    case crashed(command: String, exitCode: Int32, stderr: String)
    /// General execution failure.
    case executionFailed(command: String, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            "Mole binary not found at: \(path)"
        case .timeout(let command, let seconds):
            "Mole command '\(command)' timed out after \(Int(seconds))s"
        case .crashed(let command, let exitCode, _):
            "Mole command '\(command)' crashed (exit code \(exitCode))"
        case .executionFailed(let command, let exitCode, _):
            "Mole command '\(command)' failed (exit code \(exitCode))"
        }
    }
}

/// Configuration for MoleRunner.
public struct MoleRunnerConfig: Sendable {
    /// Default timeout per command in seconds.
    public let defaultTimeout: TimeInterval
    /// Explicit path to the `mo` binary. If nil, resolved from app bundle.
    public let binaryPath: String?

    public init(defaultTimeout: TimeInterval = 60, binaryPath: String? = nil) {
        self.defaultTimeout = defaultTimeout
        self.binaryPath = binaryPath
    }
}

/// Executes the bundled Mole (`mo`) CLI as a subprocess with timeout and crash isolation.
///
/// Each command runs in its own `Process` instance. The parent app's TCC entitlements
/// are inherited automatically by child processes signed with the same team ID.
///
/// Usage:
/// ```swift
/// let runner = MoleRunner()
/// let result = try await runner.run(command: "scan", arguments: ["--json", "/path"])
/// ```
public final class MoleRunner: Sendable {
    public let config: MoleRunnerConfig

    public init(config: MoleRunnerConfig = MoleRunnerConfig()) {
        self.config = config
    }

    /// Resolve the path to the bundled `mo` binary.
    ///
    /// Checks in order:
    /// 1. Explicit `config.binaryPath` if set
    /// 2. `MOLE_BINARY_PATH` environment variable
    /// 3. `Bundle.main.resourceURL/mo` (packaged .app)
    /// 4. `Bundle.main.bundleURL/Contents/Resources/mo` (packaged .app)
    /// 5. Homebrew locations (`/opt/homebrew/bin/mo`, `/usr/local/bin/mo`) — dev fallback
    public func resolveBinaryPath() throws -> String {
        if let explicit = config.binaryPath {
            guard FileManager.default.fileExists(atPath: explicit) else {
                throw MoleError.binaryNotFound(searchedPath: explicit)
            }
            return explicit
        }

        if let envPath = ProcessInfo.processInfo.environment["MOLE_BINARY_PATH"],
           !envPath.isEmpty,
           FileManager.default.fileExists(atPath: envPath) {
            return envPath
        }

        if let resourceURL = Bundle.main.resourceURL {
            let path = resourceURL.appendingPathComponent("mo").path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        let contentsResources = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/mo").path
        if FileManager.default.fileExists(atPath: contentsResources) {
            return contentsResources
        }

        for brewPath in ["/opt/homebrew/bin/mo", "/usr/local/bin/mo"] {
            if FileManager.default.fileExists(atPath: brewPath) {
                return brewPath
            }
        }

        let searched = Bundle.main.resourceURL?.appendingPathComponent("mo").path ?? contentsResources
        throw MoleError.binaryNotFound(searchedPath: searched)
    }

    /// Run a Mole CLI command with timeout.
    ///
    /// - Parameters:
    ///   - command: The Mole subcommand (e.g., "scan", "clean", "status").
    ///   - arguments: Additional arguments after the subcommand.
    ///   - timeout: Override timeout in seconds. Uses `config.defaultTimeout` if nil.
    /// - Returns: The run result with stdout, stderr, and exit code.
    /// - Throws: `MoleError` on timeout, crash, binary not found, or execution failure.
    public func run(
        command: String,
        arguments: [String] = [],
        timeout: TimeInterval? = nil
    ) async throws -> MoleRunResult {
        let binaryPath = try resolveBinaryPath()
        let effectiveTimeout = timeout ?? config.defaultTimeout
        let fullArgs = [command] + arguments

        logger.info("Running: mo \(fullArgs.joined(separator: " "), privacy: .public) (timeout: \(Int(effectiveTimeout))s)")

        let start = CFAbsoluteTimeGetCurrent()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = fullArgs

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment

        let finalResult: MoleRunResult = try await withThrowingTaskGroup(of: MoleRunResult?.self) { group in
            // Process execution task
            group.addTask {
                try await self.awaitProcess(process, stdout: stdoutPipe, stderr: stderrPipe)
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                return nil // nil signals timeout
            }

            // First to complete wins
            let firstResult = try await group.next()!

            // Cancel remaining tasks and kill process if still running
            group.cancelAll()
            if process.isRunning {
                process.terminate()
            }

            guard let runResult = firstResult else {
                logger.error("Mole command '\(command, privacy: .public)' timed out after \(Int(effectiveTimeout))s")
                throw MoleError.timeout(command: command, seconds: effectiveTimeout)
            }

            let duration = CFAbsoluteTimeGetCurrent() - start
            return MoleRunResult(
                stdout: runResult.stdout,
                stderr: runResult.stderr,
                exitCode: runResult.exitCode,
                duration: duration
            )
        }

        // Classify non-zero exits
        if finalResult.exitCode != 0 {
            let stderr = finalResult.stderrString
            logger.error("Mole command '\(command, privacy: .public)' exited with code \(finalResult.exitCode): \(stderr, privacy: .public)")

            // Signal-based exits (128+signal) indicate crashes
            if finalResult.exitCode > 128 {
                throw MoleError.crashed(
                    command: command,
                    exitCode: finalResult.exitCode,
                    stderr: stderr
                )
            }

            throw MoleError.executionFailed(
                command: command,
                exitCode: finalResult.exitCode,
                stderr: stderr
            )
        }

        logger.info("Mole command '\(command, privacy: .public)' completed in \(String(format: "%.2f", finalResult.duration))s")
        return finalResult
    }

    /// Await a configured Process and capture its output.
    private func awaitProcess(
        _ process: Process,
        stdout stdoutPipe: Pipe,
        stderr stderrPipe: Pipe
    ) async throws -> MoleRunResult {
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                continuation.resume(returning: MoleRunResult(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: process.terminationStatus,
                    duration: 0 // Caller computes actual duration
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: MoleError.executionFailed(
                    command: process.arguments?.first ?? "unknown",
                    exitCode: -1,
                    stderr: error.localizedDescription
                ))
            }
        }
    }
}
