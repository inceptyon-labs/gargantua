import Foundation

public enum ProcessRunnerError: Error, LocalizedError, Sendable, Equatable {
    case timedOut(seconds: TimeInterval)
    case spawnFailed(errno: Int32)
    case waitFailed(errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            "Process did not finish within \(Int(seconds))s and was terminated."
        case .spawnFailed(let errno):
            "Failed to spawn process (errno \(errno))."
        case .waitFailed(let errno):
            "Failed to wait for process exit (errno \(errno))."
        }
    }
}
