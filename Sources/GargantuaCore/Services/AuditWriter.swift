import Foundation
import os

/// Appends audit entries to a JSONL log file.
///
/// Each entry is written as a single JSON line to
/// `~/Library/Logs/Gargantua/audit.json`. Appends use an `O_APPEND` file
/// descriptor so writes are atomic at the kernel level: multiple `AuditWriter`
/// instances — and separate processes like the app and the MCP server — can
/// append to the same file without interleaving or clobbering each other. The
/// in-process lock only orders this instance's own callers.
public final class AuditWriter: Sendable {
    /// Directory containing the audit log.
    public let logDirectory: URL
    /// Full path to the audit log file.
    public let logFile: URL

    /// Orders writes from *this* instance's callers. Cross-instance and
    /// cross-process safety comes from `O_APPEND`, not this lock.
    private let lock = OSAllocatedUnfairLock()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Creates an AuditWriter targeting the given directory.
    ///
    /// Defaults to `~/Library/Logs/Gargantua/`.
    public init(logDirectory: URL? = nil) {
        let dir = logDirectory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Gargantua")
        self.logDirectory = dir
        self.logFile = dir.appendingPathComponent("audit.json")
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

        try lock.withLock {
            try FileManager.default.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: true
            )

            // O_APPEND has the kernel seek to EOF and write as one atomic step,
            // so a concurrent writer (another instance, or another process) can't
            // land its bytes between our seek and our write and tear a line.
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
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: logFile.path) else { return 0 }

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
            // rewrite, never on their own: this is a read-modify-write whose
            // final atomic rename replaces the inode, so a concurrent O_APPEND
            // from the MCP server process would be silently destroyed. Firing it
            // whenever any completed operation exists — i.e. almost always —
            // would widen that window inside the very subsystem this two-phase
            // record exists to protect. The reader collapses superseded lines
            // anyway, so leaving them on disk costs one ~300-byte line per op.
            if purgedCount > 0 {
                let newContent = keptLines.joined(separator: "\n") + (keptLines.isEmpty ? "" : "\n")
                try Data(newContent.utf8).write(to: logFile, options: .atomic)
            }

            return purgedCount
        }
    }
}

/// Errors that can occur during audit writing.
public enum AuditWriteError: Error, LocalizedError {
    case encodingFailed
    case openFailed(code: Int32)
    case writeFailed(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: "Failed to encode audit entry as UTF-8"
        case let .openFailed(code): "Failed to open audit log for appending (errno \(code))"
        case let .writeFailed(code): "Failed to append to audit log (errno \(code))"
        }
    }
}
