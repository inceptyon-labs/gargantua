import Foundation

public struct ProcessOutput: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    /// True when the child produced more stdout than the runner was willing
    /// to retain. The returned `stdout` is the truncated prefix.
    public let stdoutTruncated: Bool
    /// True when the child produced more stderr than the runner was willing
    /// to retain. The returned `stderr` is the truncated prefix.
    public let stderrTruncated: Bool

    public init(
        stdout: String,
        stderr: String,
        exitCode: Int32,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }
}
