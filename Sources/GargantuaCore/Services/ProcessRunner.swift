import Foundation

/// Runs an external process and returns captured stdout.
///
/// Broken out as a protocol so tests can stub binaries (czkawka_cli, fclones)
/// without actually spawning a subprocess.
public protocol ProcessRunner: Sendable {
    func run(executable: URL, arguments: [String]) throws -> ProcessOutput

    /// Run with a wall-clock timeout. A nil timeout means no limit.
    /// Default implementation ignores the timeout and delegates to `run(executable:arguments:)`;
    /// runners that actually spawn processes (e.g. `DefaultProcessRunner`) override this.
    func run(executable: URL, arguments: [String], timeout: TimeInterval?) throws -> ProcessOutput

    /// Run with a wall-clock timeout and a byte cap on captured stdout/stderr.
    /// Bytes past `maxCapturedBytes` are read from the pipe (so the child is
    /// not blocked on a full buffer) but dropped from the returned payload,
    /// and the corresponding `stdoutTruncated` / `stderrTruncated` flag is
    /// set. Default implementation ignores the cap and delegates to the
    /// timeout-only overload; runners that actually spawn processes override
    /// this.
    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval?,
        maxCapturedBytes: Int
    ) throws -> ProcessOutput
}

public extension ProcessRunner {
    func run(executable: URL, arguments: [String], timeout: TimeInterval?) throws -> ProcessOutput {
        try run(executable: executable, arguments: arguments)
    }

    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval?,
        maxCapturedBytes _: Int
    ) throws -> ProcessOutput {
        try run(executable: executable, arguments: arguments, timeout: timeout)
    }
}
