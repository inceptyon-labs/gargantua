import Foundation
import os

/// Appends audit entries to a JSONL log file.
///
/// Each entry is written as a single JSON line to
/// `~/Library/Logs/Gargantua/audit.json`. Writes are serialized
/// via `OSAllocatedUnfairLock` to ensure thread safety.
public final class AuditWriter: Sendable {
    /// Directory containing the audit log.
    public let logDirectory: URL
    /// Full path to the audit log file.
    public let logFile: URL

    /// Serializes file writes to prevent interleaved output from concurrent callers.
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

            if FileManager.default.fileExists(atPath: logFile.path) {
                let handle = try FileHandle(forWritingTo: logFile)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(lineData)
            } else {
                try lineData.write(to: logFile, options: .atomic)
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

    // MARK: - Reading

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Read all audit entries from the log file.
    ///
    /// Returns an empty array if the log file doesn't exist.
    /// Skips malformed lines rather than failing entirely.
    public func readEntries() throws -> [AuditEntry] {
        guard FileManager.default.fileExists(atPath: logFile.path) else { return [] }

        let content = try String(contentsOf: logFile, encoding: .utf8)
        return content.split(separator: "\n").compactMap { line in
            try? Self.decoder.decode(AuditEntry.self, from: Data(line.utf8))
        }
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

            var keptLines: [String] = []
            var purgedCount = 0

            for line in lines {
                if let entry = try? Self.decoder.decode(AuditEntry.self, from: Data(line.utf8)) {
                    if entry.timestamp >= cutoff {
                        keptLines.append(String(line))
                    } else {
                        purgedCount += 1
                    }
                } else {
                    // Keep malformed lines to avoid silent data loss
                    keptLines.append(String(line))
                }
            }

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

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: "Failed to encode audit entry as UTF-8"
        }
    }
}
