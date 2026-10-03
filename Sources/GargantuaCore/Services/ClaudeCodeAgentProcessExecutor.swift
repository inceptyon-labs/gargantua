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
        // Same pre-exec check DefaultProcessRunner applies to every other tool.
        try ExecutableTrustPolicy.verify(executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("DYLD_") }
            .merging(environment) { _, new in new }
        process.currentDirectoryURL = workingDirectory

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutDecoder = UTF8ChunkDecoder()
        let stderrDecoder = UTF8ChunkDecoder()

        setCurrentProcess(process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeState = ResumeState<Int32>()

                let finish: @Sendable (Result<Int32, Error>, Bool) -> Void = { [weak self] result, drainPipes in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    if drainPipes {
                        // Short-lived processes (e.g. `echo`) can terminate before the
                        // readabilityHandler ever fires; without this drain their output
                        // sits buffered in the pipe and is lost when the handler is cleared.
                        let remainingStdout = stdoutDecoder.decode(stdout.fileHandleForReading.availableData, isFinal: true)
                        if !remainingStdout.isEmpty {
                            onOutput(.stdout(remainingStdout))
                        }
                        let remainingStderr = stderrDecoder.decode(stderr.fileHandleForReading.availableData, isFinal: true)
                        if !remainingStderr.isEmpty {
                            onOutput(.stderr(remainingStderr))
                        }
                    }
                    self?.clearCurrentProcess(process)
                    resumeState.resume(result, continuation: continuation)
                }

                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let text = stdoutDecoder.decode(handle.availableData)
                    guard !text.isEmpty else { return }
                    onOutput(.stdout(text))
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let text = stderrDecoder.decode(handle.availableData)
                    guard !text.isEmpty else { return }
                    onOutput(.stderr(text))
                }
                process.terminationHandler = { process in
                    finish(.success(process.terminationStatus), true)
                }

                do {
                    try process.run()
                } catch {
                    finish(.failure(error), false)
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

private final class ResumeState<Value: Sendable>: @unchecked Sendable {
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

/// Decodes a byte stream that arrives in arbitrary chunks. A pipe read can
/// end partway through a multi-byte character; decoding each chunk alone
/// turned that whole chunk into "" (`String(data:encoding:)` fails), losing
/// a block of the agent's output. The incomplete tail is held for the next
/// chunk instead.
final class UTF8ChunkDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    /// - Parameter isFinal: no more bytes follow; a leftover partial
    ///   character is decoded as U+FFFD rather than held.
    func decode(_ data: Data, isFinal: Bool = false) -> String {
        let bytes: Data = lock.withLock {
            var combined = pending
            combined.append(data)
            let keep = isFinal ? 0 : Self.incompleteTailLength(combined)
            pending = combined.suffix(keep)
            return combined.dropLast(keep)
        }
        // Lossy on purpose: an invalid byte becomes U+FFFD instead of the
        // failable initializer discarding the whole chunk.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Bytes at the end of `data` that start a UTF-8 sequence too short to
    /// finish yet (0–3).
    static func incompleteTailLength(_ data: Data) -> Int {
        let tail = Array(data.suffix(4))
        guard !tail.isEmpty else { return 0 }
        for back in 1 ... min(3, tail.count) {
            let byte = tail[tail.count - back]
            if byte & 0b1100_0000 == 0b1000_0000 { continue } // continuation byte
            let needed: Int = if byte & 0b1110_0000 == 0b1100_0000 {
                2
            } else if byte & 0b1111_0000 == 0b1110_0000 {
                3
            } else if byte & 0b1111_1000 == 0b1111_0000 {
                4
            } else {
                1
            }
            return needed > back ? back : 0
        }
        return 0
    }
}
