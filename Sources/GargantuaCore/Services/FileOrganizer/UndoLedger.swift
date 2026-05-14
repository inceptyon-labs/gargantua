import Foundation
import os

/// Append-only JSONL ledger of organizer moves. Each successful move
/// writes one `UndoEntry` line so an Apply can be reversed file-by-file
/// — and so a crash mid-Apply still leaves a recoverable trail.
///
/// Default location: `~/Library/Application Support/Gargantua/organizer-undo.json`.
/// Writes are serialized via `OSAllocatedUnfairLock`. Format mirrors
/// `AuditWriter`: one JSON object per line, ISO-8601 dates, sorted keys.
public final class UndoLedger: Sendable {
    public let ledgerDirectory: URL
    public let ledgerFile: URL
    private let lock = OSAllocatedUnfairLock()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(ledgerDirectory: URL? = nil) {
        let dir = ledgerDirectory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Gargantua", isDirectory: true)
        self.ledgerDirectory = dir
        self.ledgerFile = dir.appendingPathComponent("organizer-undo.json")
    }

    /// Append one entry to the ledger. Creates the directory and file
    /// on first call. Thread-safe.
    public func append(_ entry: UndoEntry) throws {
        let data = try Self.encoder.encode(entry)
        guard var line = String(data: data, encoding: .utf8) else {
            throw UndoLedgerError.encodingFailed
        }
        line.append("\n")
        let lineData = Data(line.utf8)

        try lock.withLock {
            try FileManager.default.createDirectory(
                at: ledgerDirectory,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: ledgerFile.path) {
                let handle = try FileHandle(forWritingTo: ledgerFile)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(lineData)
            } else {
                try lineData.write(to: ledgerFile, options: .atomic)
            }
        }
    }

    /// All entries currently on disk. Malformed lines are skipped, not
    /// raised — a single corrupt line should not block undo for the rest.
    public func readAll() throws -> [UndoEntry] {
        guard FileManager.default.fileExists(atPath: ledgerFile.path) else { return [] }
        let content = try String(contentsOf: ledgerFile, encoding: .utf8)
        return content.split(separator: "\n").compactMap { line in
            try? Self.decoder.decode(UndoEntry.self, from: Data(line.utf8))
        }
    }

    /// Entries that belong to one proposal. Used by `OrganizerExecutor.undo`.
    public func entries(forProposalID proposalID: UUID) throws -> [UndoEntry] {
        try readAll().filter { $0.proposalID == proposalID }
    }

    /// Drop all entries for a proposal. Called after a successful Undo
    /// so the ledger doesn't accumulate stale records. Other proposals'
    /// entries are preserved.
    public func clear(proposalID: UUID) throws {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: ledgerFile.path) else { return }
            let content = try String(contentsOf: ledgerFile, encoding: .utf8)
            let keptLines: [String] = content.split(separator: "\n").compactMap { line in
                let entry = try? Self.decoder.decode(UndoEntry.self, from: Data(line.utf8))
                // Keep malformed lines as-is to avoid silent data loss
                // and keep any entry not tied to this proposal.
                if entry == nil { return String(line) }
                if entry?.proposalID == proposalID { return nil }
                return String(line)
            }
            let newContent = keptLines.isEmpty ? "" : keptLines.joined(separator: "\n") + "\n"
            try Data(newContent.utf8).write(to: ledgerFile, options: .atomic)
        }
    }
}

public enum UndoLedgerError: Error, LocalizedError {
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: "Failed to encode undo entry as UTF-8"
        }
    }
}
