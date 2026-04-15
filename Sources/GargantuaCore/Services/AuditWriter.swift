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
    public func record(result: CleanupResult, tool: String = "native", command: String = "clean") throws {
        let succeeded = result.succeededItems
        guard !succeeded.isEmpty else { return }

        let highestSafety = succeeded.map(\.item.safety).reduce(SafetyLevel.safe) { current, next in
            switch (current, next) {
            case (.protected_, _), (_, .protected_): .protected_
            case (.review, _), (_, .review): .review
            default: .safe
            }
        }

        let tier = confirmationTier(for: succeeded.map(\.item))

        let entry = AuditEntry(
            tool: tool,
            command: command,
            files: succeeded.map { AuditFile(path: $0.item.path, size: $0.item.size) },
            safetyLevel: highestSafety,
            confirmationMethod: tier,
            bytesFreed: result.totalFreed
        )

        try write(entry)
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
