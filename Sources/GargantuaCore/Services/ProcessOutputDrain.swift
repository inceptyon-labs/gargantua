import Foundation

/// Owns the stdout/stderr pipe pair for one spawned child: creates the pipes,
/// pulls bytes off both concurrently under a byte cap, and hands back the
/// captured payload.
///
/// Split out of `DefaultProcessRunner.run` so the capture rules — bounded
/// chunk reads, the cap, the grace-period force-close — live in one place
/// rather than interleaved with spawn and reap.
struct ProcessOutputDrain {
    /// Read in bounded chunks rather than `readToEnd()`: the latter allocates
    /// one `Data` for the entire stream, defeating the byte cap.
    private static let chunkSize = 16 * 1024

    /// Pipe ends close on child exit, so the blocking reads should return
    /// shortly after waitpid. However, if a descendant inherited the fd and is
    /// still writing, the read could hang indefinitely. Use a fixed 1s grace:
    /// the child has already exited, so drain budget has no relationship to
    /// the original wall-clock timeout. Previous `timeout * 0.1` scaling gave
    /// 0.5s for a 5s timeout which, under heavy parallel load, wasn't enough
    /// for the `.userInitiated` drain tasks to even schedule before the
    /// force-close fired. 1s is long enough to drain bounded kernel pipe
    /// buffers under load, short enough to keep run() bounded when a
    /// descendant genuinely holds the inherited fd.
    private static let drainGrace: TimeInterval = 1.0

    /// Extra wait after force-closing the fds, for the drain tasks to unwind.
    private static let forceCloseGrace: TimeInterval = 0.1

    let stdoutPipe: Pipe
    let stderrPipe: Pipe

    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let stdoutBuffer: ProcessOutputBuffer
    private let stderrBuffer: ProcessOutputBuffer
    private let group = DispatchGroup()

    init(maxCapturedBytes: Int) {
        let outPipe = Pipe()
        let errPipe = Pipe()
        stdoutPipe = outPipe
        stderrPipe = errPipe
        stdoutHandle = outPipe.fileHandleForReading
        stderrHandle = errPipe.fileHandleForReading
        stdoutBuffer = ProcessOutputBuffer(limit: maxCapturedBytes)
        stderrBuffer = ProcessOutputBuffer(limit: maxCapturedBytes)
    }

    /// Close the write ends in the parent so EOF on the read ends happens when
    /// the child exits (if no descendant inherited them). Failing to close
    /// these would leave the drain reads blocked forever. Then drain each pipe
    /// on a dedicated background task with bounded chunk reads.
    ///
    /// This is deliberately simpler than a readabilityHandler + post-exit
    /// readDataToEndOfFile pair: that approach can race because setting the
    /// handler to nil is not documented to block for in-flight invocations, so
    /// a late handler chunk can interleave with the final drain. Draining both
    /// pipes concurrently also prevents a full 64K buffer on one stream from
    /// blocking the child while we sit on waitpid.
    ///
    /// `.userInitiated` rather than `.utility`: the drain reads are on the
    /// critical path of returning correct stdout to the caller. Under heavy
    /// parallel subprocess load (10+ concurrent runners), `.utility` tasks
    /// could be starved long enough for the grace-period force-close to fire
    /// before `readToEnd()` was ever scheduled, returning empty output for a
    /// child that had cleanly produced bytes.
    ///
    /// - Precondition: the child must already be spawned — the write ends have
    ///   to stay open through `posix_spawn` for the child to inherit them.
    func startDraining() {
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let queue = DispatchQueue.global(qos: .userInitiated)
        let outHandle = stdoutHandle
        let outBuffer = stdoutBuffer
        queue.async(group: group) {
            Self.drainPipe(handle: outHandle, into: outBuffer)
        }
        let errHandle = stderrHandle
        let errBuffer = stderrBuffer
        queue.async(group: group) {
            Self.drainPipe(handle: errHandle, into: errBuffer)
        }
    }

    /// Wait for both drains to reach EOF, force-closing the read fds if a
    /// descendant is holding them open past the grace period.
    func finish() {
        guard group.wait(timeout: .now() + Self.drainGrace) == .timedOut else { return }
        // Force-close the pipe file descriptors to unblock the pending reads.
        // This prevents an indefinite hang if a descendant inherited the fds.
        try? stdoutHandle.close()
        try? stderrHandle.close()
        _ = group.wait(timeout: .now() + Self.forceCloseGrace)
    }

    /// Assemble the captured payload. Uses a lossy UTF-8 decode: truncation at
    /// the cap can slice a multi-byte codepoint, and
    /// `String(data:, encoding: .utf8)` returns nil in that case — a `?? ""`
    /// fallback would throw away the entire (otherwise useful) prefix.
    /// `String(decoding:as:)` substitutes U+FFFD for the partial sequence and
    /// preserves the rest.
    func makeOutput(exitCode: Int32) -> ProcessOutput {
        // swiftlint:disable optional_data_string_conversion
        let stdout = String(decoding: stdoutBuffer.snapshot(), as: UTF8.self)
        let stderr = String(decoding: stderrBuffer.snapshot(), as: UTF8.self)
        // swiftlint:enable optional_data_string_conversion
        return ProcessOutput(
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            stdoutTruncated: stdoutBuffer.wasTruncated(),
            stderrTruncated: stderrBuffer.wasTruncated()
        )
    }

    /// Pulls bytes from `handle` in bounded chunks until EOF or the handle is
    /// closed. `buffer` may drop bytes past its cap; we still keep reading to
    /// avoid blocking the child on a full kernel pipe buffer.
    ///
    /// The throwing `read(upToCount:)` returns empty Data on EOF and throws
    /// when the force-close path closes the fd out from under a blocking read
    /// (legacy `availableData` would raise an NSException and crash).
    private static func drainPipe(handle: FileHandle, into buffer: ProcessOutputBuffer) {
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                // Force-close path closed the fd out from under us; treat as EOF.
                return
            }
            guard let chunk, !chunk.isEmpty else { return }
            buffer.append(chunk)
        }
    }
}
