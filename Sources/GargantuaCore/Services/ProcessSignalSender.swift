import Darwin
import Foundation

/// Result of sending one signal to a process.
public struct ProcessSignalResult: Sendable, Equatable {
    /// `0` on success, otherwise the `errno` value `kill(2)` reported.
    public let errno: Int32
    /// Signal number that was sent (`SIGTERM`, `SIGKILL`, …).
    public let signal: Int32

    public var succeeded: Bool { errno == 0 }
    /// `kill(2)` returns `ESRCH` when the target PID no longer exists. Treat
    /// that as success for stop semantics — the process is already gone.
    public var alreadyGone: Bool { errno == ESRCH }

    public init(errno: Int32, signal: Int32) {
        self.errno = errno
        self.signal = signal
    }
}

/// Testable wrapper around `kill(2)`. Default implementation calls Darwin
/// directly; tests inject a fake to exercise escalation logic without
/// signaling real processes.
public protocol ProcessSignalSending: Sendable {
    /// Send `signal` to `pid`. Returns `ProcessSignalResult` capturing errno.
    func send(_ signal: Int32, to pid: Int32) -> ProcessSignalResult
    /// Probe whether `pid` is currently addressable. Implemented as
    /// `kill(pid, 0)` in the default — returns `false` on `ESRCH`.
    func isAlive(pid: Int32) -> Bool
}

public struct DefaultProcessSignalSender: ProcessSignalSending {
    public init() {}

    public func send(_ signal: Int32, to pid: Int32) -> ProcessSignalResult {
        // `kill(2)` returns -1 on failure with errno set, 0 on success.
        let result = Darwin.kill(pid, signal)
        if result == 0 { return ProcessSignalResult(errno: 0, signal: signal) }
        return ProcessSignalResult(errno: Darwin.errno, signal: signal)
    }

    public func isAlive(pid: Int32) -> Bool {
        // Sending signal 0 doesn't deliver — it just performs the
        // permission/existence check. ESRCH means the PID is gone.
        let result = Darwin.kill(pid, 0)
        if result == 0 { return true }
        return Darwin.errno != ESRCH
    }
}
