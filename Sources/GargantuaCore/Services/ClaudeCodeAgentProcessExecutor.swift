import Foundation

public enum ClaudeCodeProcessOutput: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
}

public protocol ClaudeCodeAgentProcessExecuting: AnyObject, Sendable {
    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        onOutput: @escaping @Sendable (ClaudeCodeProcessOutput) -> Void
    ) async throws -> Int32

    func cancel()
}

public final class FoundationClaudeCodeProcessExecutor: ClaudeCodeAgentProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    public init() {}

    public func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        onOutput: @escaping @Sendable (ClaudeCodeProcessOutput) -> Void
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.currentDirectoryURL = workingDirectory

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        setCurrentProcess(process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeState = ResumeState<Int32>()

                let finish: @Sendable (Result<Int32, Error>) -> Void = { [weak self] result in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    self?.clearCurrentProcess(process)
                    resumeState.resume(result, continuation: continuation)
                }

                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    onOutput(.stdout(String(data: data, encoding: .utf8) ?? ""))
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    onOutput(.stderr(String(data: data, encoding: .utf8) ?? ""))
                }
                process.terminationHandler = { process in
                    finish(.success(process.terminationStatus))
                }

                do {
                    try process.run()
                } catch {
                    finish(.failure(error))
                }
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    public func cancel() {
        let current = currentProcess()

        guard let current, current.isRunning else { return }
        current.terminate()
    }

    private func setCurrentProcess(_ process: Process?) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    private func clearCurrentProcess(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    private func currentProcess() -> Process? {
        lock.lock()
        defer { lock.unlock() }
        return process
    }
}

private final class ResumeState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ result: Result<Value, Error>,
        continuation: CheckedContinuation<Value, Error>
    ) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
