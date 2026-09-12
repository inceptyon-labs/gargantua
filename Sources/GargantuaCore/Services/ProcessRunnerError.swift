import Foundation

public enum ProcessRunnerError: Error, LocalizedError, Sendable, Equatable {
    case timedOut(seconds: TimeInterval)
    case spawnFailed(errno: Int32)
    case waitFailed(errno: Int32)
    /// The executable failed `ExecutableTrustPolicy` and was never spawned.
    case untrustedExecutable(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            "Process did not finish within \(Int(seconds))s and was terminated."
        case .spawnFailed(let errno):
            "Failed to spawn process (errno \(errno))."
        case .waitFailed(let errno):
            "Failed to wait for process exit (errno \(errno))."
        case .untrustedExecutable(let path, let reason):
            "Refused to run \(path): \(reason)."
        }
    }
}
