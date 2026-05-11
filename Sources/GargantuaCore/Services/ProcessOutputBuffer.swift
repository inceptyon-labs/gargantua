import Foundation

/// Thread-safe byte buffer with a hard size cap used by `DefaultProcessRunner`
/// to capture stdout/stderr from spawned children. Bytes past `limit` are
/// dropped from the snapshot but the writer still calls `append` so the
/// surrounding drain loop keeps reading from the pipe — otherwise the child
/// would block on a full kernel pipe buffer.
final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false
    private let limit: Int

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let remaining = limit - data.count
        if remaining <= 0 {
            truncated = true
            return
        }
        if chunk.count <= remaining {
            data.append(chunk)
        } else {
            data.append(chunk.prefix(remaining))
            truncated = true
        }
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }

    func wasTruncated() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return truncated
    }
}
