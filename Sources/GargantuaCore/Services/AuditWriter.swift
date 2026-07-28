import Foundation
import os

/// Appends audit entries to a JSONL log file.
///
/// Each entry is written as a single JSON line to
/// `~/Library/Logs/Gargantua/audit.json`. Appends use an `O_APPEND` file
/// descriptor so writes are atomic at the kernel level: multiple `AuditWriter`
/// instances — and separate processes like the app and the MCP server — can
/// append to the same file without interleaving. Mutation that is *not* a plain
/// append (`purgeEntries`, a read-modify-write ending in an atomic rename) is
/// excluded against appends by an `flock` on the `audit.lock` sidecar — see
/// `lockFile` for why that sidecar does not live beside the log by default.
public final class AuditWriter: Sendable {
    /// Directory containing the audit log.
    public let logDirectory: URL
    /// Full path to the audit log file.
    public let logFile: URL

    /// Sidecar file whose inode never changes, used to coordinate log mutation.
    ///
    /// The lock cannot live on `audit.json`: `purgeEntries` finishes with an
    /// atomic rename that swaps that file's inode, so an `flock` taken on it
    /// would be stranded on the now-unlinked inode and stop excluding anyone.
    ///
    /// It also cannot live in `~/Library/Logs/Gargantua`: the bundled
    /// `system_logs` rule sweeps `~/Library/Logs`, and the only thing sparing
    /// our directory is an `exclude` line owned by the upstream rules repo. If
    /// that exclusion ever narrows, a Deep Clean would unlink the sidecar out
    /// from under a process holding `flock` on it, the next writer would create
    /// a fresh inode, and the two would proceed unsynchronised. Application
    /// Support is where this app already keeps durable state and no bundled
    /// rule reaches a file at its root.
    public let lockFile: URL

    /// Take an exclusive `flock` on the sidecar, returning the locked descriptor.
    ///
    /// `flock` conflicts between distinct open file descriptions, so this orders
    /// separate processes — the app and the MCP server — and separate
    /// `AuditWriter` instances within one process. It is NOT reentrant: each
    /// call opens a fresh descriptor, so a nested call self-deadlocks against
    /// the lock its own caller already holds.
    private func acquireFileLock() throws -> Int32 {
        // O_RDONLY, not O_WRONLY: flock works on a read-only descriptor, and
        // opening for write fails with EACCES when the log directory is
        // read-only, or when the sidecar was created by a differently
        // privileged process (one `sudo` run leaves it root-owned).
        // The sidecar no longer necessarily lives in the log directory (see
        // `init`), and `open(O_CREAT)` will not create missing parents. Ignore
        // the result: if the directory genuinely can't be made, the `open`
        // below fails and reports the real errno as `lockFailed`.
        try? FileManager.default.createDirectory(
            at: lockFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fd = Darwin.open(lockFile.path, O_RDONLY | O_CREAT, 0o644)
        guard fd >= 0 else { throw AuditWriteError.lockFailed(code: errno) }

        // Poll rather than block: LOCK_EX alone has no timeout, and an
        // unbounded wait on a peer process would hang the caller's thread.
        let deadline = Date().addingTimeInterval(lockTimeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EINTR || code == EWOULDBLOCK, Date() < deadline else {
                Darwin.close(fd)
                throw AuditWriteError.lockFailed(code: code)
            }
            // Retry a signal-interrupted call immediately; back off only when
            // the lock is genuinely held by someone else.
            if code == EWOULDBLOCK { Thread.sleep(forTimeInterval: 0.01) }
        }
        return fd
    }

    /// Release a descriptor returned by `acquireFileLock`.
    private func releaseFileLock(_ fd: Int32) {
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
    }

    /// Append one already-encoded line via an `O_APPEND` descriptor.
    ///
    /// O_APPEND has the kernel seek to EOF and write as one atomic step, so a
    /// concurrent writer — another instance, or another process — can't land
    /// its bytes between our seek and our write and tear a line.
    private func appendLine(_ lineData: Data) throws {
        let fd = Darwin.open(logFile.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw AuditWriteError.openFailed(code: errno)
        }
        defer { Darwin.close(fd) }

        try lineData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AuditWriteError.writeFailed(code: errno)
                }
                offset += written
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// How long a caller waits for the sidecar before giving up.
    ///
    /// `flock(LOCK_EX)` blocks forever, and `write(_:)` runs on the main thread
    /// from the Deep Clean confirmation path — a wedged peer process holding the
    /// sidecar would beachball the app with no cancel. Bound the wait instead.
    /// Clamped to [0, 60]: a negative or non-finite bound would silently turn
    /// every acquisition into an immediate failure or an unbounded wait.
    private let lockTimeout: TimeInterval

    /// Creates an AuditWriter targeting the given directory.
    ///
    /// Defaults: log in `~/Library/Logs/Gargantua/`, sidecar in
    /// `~/Library/Application Support/Gargantua/`. A caller that names its own
    /// `logDirectory` — every test, and any embedder — gets the sidecar
    /// alongside its log instead, so two writers pointed at one directory still
    /// exclude each other without contending on a process-wide shared path.
    public init(
        logDirectory: URL? = nil,
        lockDirectory: URL? = nil,
        lockTimeout: TimeInterval = 2
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = logDirectory ?? home.appendingPathComponent("Library/Logs/Gargantua")
        self.logDirectory = dir
        self.logFile = dir.appendingPathComponent("audit.json")

        let defaultLockDir = logDirectory == nil
            ? home.appendingPathComponent("Library/Application Support/Gargantua")
            : dir
        self.lockFile = (lockDirectory ?? defaultLockDir)
            .appendingPathComponent("audit.lock")

        self.lockTimeout = lockTimeout.isFinite ? min(max(lockTimeout, 0), 60) : 60
    }

    /// Write an audit entry for a completed cleanup operation.
    ///
    /// Creates the log directory if it doesn't exist. Appends the entry
    /// as a single JSON line (JSONL format). Thread-safe — concurrent
    /// calls are serialized.
    public func write(_ entry: AuditEntry) throws {
        let data = try Self.encoder.encode(entry)
        guard var line = String(data: data, encoding: .utf8) else {
            throw AuditWriteError.encodingFailed
        }
        line.append("\n")
        let lineData = Data(line.utf8)

        try FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )

        // Appending without the sidecar would reintroduce the clobber this
        // guards against — a purge that outlives the timeout is exactly when
        // the rewrite is in flight, so an unlocked append would land on the
        // inode about to be discarded and vanish with a success return. A
        // reported failure the caller can log beats a silent loss.
        let fd = try acquireFileLock()
        defer { releaseFileLock(fd) }

        try appendLine(lineData)
    }

    /// Build an AuditEntry from a CleanupResult and write it.
    public func record(
        result: CleanupResult,
        tool: String = "native",
        command: String = "clean",
        confirmationMethod: ConfirmationTier? = nil
    ) throws {
        let succeeded = result.succeededItems
        guard !succeeded.isEmpty else { return }

        let highestSafety = succeeded.map(\.item.safety).reduce(SafetyLevel.safe) { current, next in
            switch (current, next) {
            case (.protected_, _), (_, .protected_): .protected_
            case (.review, _), (_, .review): .review
            default: .safe
            }
        }

        let tier = confirmationMethod ?? confirmationTier(for: succeeded.map(\.item))

        let entry = AuditEntry(
            tool: tool,
            command: command,
            files: succeeded.map { AuditFile(path: $0.item.path, size: $0.item.size) },
            safetyLevel: highestSafety,
            confirmationMethod: tier,
            cleanupMethod: result.cleanupMethod,
            bytesFreed: result.totalFreed
        )

        try write(entry)
    }

    /// Record an MCP-initiated operation. Unlike `record(result:...)`, this
    /// overload is called for every completed clean request, including ones
    /// that failed before producing any successful items — an attempted
    /// destructive operation is worth auditing whether or not it succeeded,
    /// so forensic investigators can see what an MCP client tried to do.
    ///
    /// - Parameters:
    ///   - requested: Items the client asked to clean (resolved against the
    ///     scan cache). These are the `files` recorded in the entry.
    ///   - result: The cleaner result, or nil for failure before the cleaner
    ///     ran. When nil, `bytesFreed` is reported as 0 and the cleanup method
    ///     falls back to `methodHint`.
    ///   - methodHint: The cleanup method the client requested. Used when
    ///     `result` is nil. Ignored when `result` is present.
    ///   - clientID: Identifier of the initiating MCP client.
    ///   - tool: Engine/tool attribution. Defaults to `"native"`.
    ///   - command: Verb being audited. Defaults to `"clean"`.
    /// - Returns: The UUID of the written entry, so the caller can surface it
    ///   as `audit_id` in the tool response.
    @discardableResult
    public func recordMCP(
        requested: [ScanResult],
        result: CleanupResult?,
        methodHint: CleanupMethod = .trash,
        clientID: String,
        tool: String = "native",
        command: String = "clean"
    ) throws -> UUID {
        let files = requested.map { AuditFile(path: $0.path, size: $0.size) }

        let highestSafety = requested.map(\.safety).reduce(SafetyLevel.safe) { current, next in
            switch (current, next) {
            case (.protected_, _), (_, .protected_): .protected_
            case (.review, _), (_, .review): .review
            default: .safe
            }
        }

        let entry = AuditEntry(
            tool: tool,
            command: command,
            files: files,
            safetyLevel: highestSafety,
            // `mcp` carries its own confirmation semantics (schema-level
            // `confirm: true`); record it as a distinct tier via the stored
            // string value rather than conflating with the UI tiers.
            confirmationMethod: .mcp,
            cleanupMethod: result?.cleanupMethod ?? methodHint,
            bytesFreed: result?.totalFreed ?? 0,
            transport: "mcp",
            clientID: clientID
        )

        try write(entry)
        return entry.id
    }

    // MARK: - Reading

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// mtime + size identity of the log file at the last successful decode.
    private struct ReadCache: Sendable {
        let modificationDate: Date
        let size: UInt64
        let entries: [AuditEntry]
    }

    private let readCache = OSAllocatedUnfairLock<ReadCache?>(initialState: nil)

    /// Read all audit entries from the log file.
    ///
    /// Returns an empty array if the log file doesn't exist.
    /// Skips malformed lines rather than failing entirely.
    ///
    /// The decoded entries are cached against the file's mtime + size, so
    /// polling callers (the Dashboard status refresh) pay one stat call per
    /// tick instead of re-decoding the whole log.
    public func readEntries() throws -> [AuditEntry] {
        guard FileManager.default.fileExists(atPath: logFile.path) else { return [] }

        let attributes = try? FileManager.default.attributesOfItem(atPath: logFile.path)
        let modificationDate = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? NSNumber)?.uint64Value

        if let modificationDate, let size,
           let cached = readCache.withLock({ $0 }),
           cached.modificationDate == modificationDate, cached.size == size {
            return cached.entries
        }

        let content = try String(contentsOf: logFile, encoding: .utf8)
        let decoded = content.split(separator: "\n").compactMap { line in
            try? Self.decoder.decode(AuditEntry.self, from: Data(line.utf8))
        }
        let entries = Self.collapsingByID(decoded)

        if let modificationDate, let size {
            readCache.withLock {
                $0 = ReadCache(modificationDate: modificationDate, size: size, entries: entries)
            }
        }
        return entries
    }

    /// Collapse two-phase intent+outcome pairs into one effective entry each.
    ///
    /// A destructive operation appends an `.attempted` line before it acts and
    /// a `.completed` line after, both carrying the same `id`. Consumers want
    /// one row per operation, so the later line wins. An operation whose
    /// process died mid-act leaves only the `.attempted` line, which survives
    /// here — that surviving orphan is the forensic signal.
    ///
    /// Both the value and the position come from the last occurrence, so the
    /// returned array still reads chronologically.
    static func collapsingByID(_ entries: [AuditEntry]) -> [AuditEntry] {
        var seen: Set<UUID> = []
        var collapsed: [AuditEntry] = []
        collapsed.reserveCapacity(entries.count)
        for entry in entries.reversed() where seen.insert(entry.id).inserted {
            collapsed.append(entry)
        }
        return collapsed.reversed()
    }

    // MARK: - Retention

    /// Remove audit entries older than the given retention period.
    ///
    /// Rewrites the log file containing only entries within the retention window.
    /// Thread-safe — serialized with writes.
    ///
    /// - Parameter retentionDays: Number of days to retain (default: 90).
    /// - Returns: The number of entries purged.
    @discardableResult
    public func purgeEntries(olderThanDays retentionDays: Int = 90, now: Date = Date()) throws -> Int {
        guard FileManager.default.fileExists(atPath: logFile.path) else { return 0 }

        // Unlike write(_:), retention is deferrable — running the
        // read-modify-write without the lock is the very hazard this guards, so
        // a lock we can't take must fail the purge rather than proceed.
        let fd = try acquireFileLock()
        defer { releaseFileLock(fd) }

        let content = try String(contentsOf: logFile, encoding: .utf8)
        let lines = content.split(separator: "\n")
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)

        // Last line index per id. Anything earlier with the same id is the
        // superseded intent record of an operation that finished; the
        // reader already ignores it, so compaction drops it rather than
        // letting the log carry two lines per operation forever.
        var lastIndexByID: [UUID: Int] = [:]
        for (index, line) in lines.enumerated() {
            if let entry = try? Self.decoder.decode(AuditEntry.self, from: Data(line.utf8)) {
                lastIndexByID[entry.id] = index
            }
        }

        var keptLines: [String] = []
        var purgedCount = 0

        for (index, line) in lines.enumerated() {
            guard let entry = try? Self.decoder.decode(AuditEntry.self, from: Data(line.utf8)) else {
                // Keep malformed lines to avoid silent data loss
                keptLines.append(String(line))
                continue
            }
            if lastIndexByID[entry.id] != index {
                continue
            }
            if entry.timestamp >= cutoff {
                keptLines.append(String(line))
            } else {
                purgedCount += 1
            }
        }

        // Only rewrite when retention actually removed something. Superseded
        // intent lines are compacted opportunistically as part of that
        // rewrite, never on their own: rewriting the whole log every time a
        // completed operation exists — i.e. almost always — is pointless I/O
        // in the hot path. The reader collapses superseded lines anyway, so
        // leaving them on disk costs one ~300-byte line per operation.
        if purgedCount > 0 {
            let newContent = keptLines.joined(separator: "\n") + (keptLines.isEmpty ? "" : "\n")
            try Data(newContent.utf8).write(to: logFile, options: .atomic)
        }

        return purgedCount
    }
}

/// Errors that can occur during audit writing.
public enum AuditWriteError: Error, LocalizedError {
    case encodingFailed
    case openFailed(code: Int32)
    case writeFailed(code: Int32)
    case lockFailed(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: "Failed to encode audit entry as UTF-8"
        case let .openFailed(code): "Failed to open audit log for appending (errno \(code))"
        case let .writeFailed(code): "Failed to append to audit log (errno \(code))"
        case let .lockFailed(code): "Failed to lock the audit log for exclusive access (errno \(code))"
        }
    }
}
