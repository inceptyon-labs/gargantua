import Darwin
import Foundation

/// File-backed handoff between the MCP executable and the Dashboard app.
public struct MCPServerStatusPersistence: Sendable {
    public let url: URL

    public init(url: URL = MCPServerStatusPersistence.defaultURL()) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Gargantua", isDirectory: true)
            .appendingPathComponent("mcp-status.json")
    }

    public func readSnapshot(now: Date = Date()) throws -> MCPServerStatusSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .stopped(updatedAt: now)
        }

        let data = try Data(contentsOf: url)
        let snapshot = try Self.decoder.decode(MCPServerStatusSnapshot.self, from: data)
        guard snapshot.state == .running else {
            return snapshot
        }

        guard let processID = snapshot.processID,
              Self.isProcessRunning(processID)
        else {
            return stoppedSnapshot(from: snapshot, now: now)
        }

        return snapshot
    }

    public func stopRunningServer(now: Date = Date()) throws -> MCPServerStatusSnapshot {
        let snapshot = try readSnapshot(now: now)
        guard snapshot.state == .running else { return snapshot }

        guard let processID = snapshot.processID,
              Self.processLooksLikeGargantuaMCP(processID)
        else {
            throw MCPServerControlError.unsupported(
                "MCP stdio is owned by its launching client. Stop control requires a verified GargantuaMCP process."
            )
        }

        if kill(processID, SIGTERM) != 0, errno != ESRCH {
            throw MCPServerControlError.unsupported("MCP server could not be stopped.")
        }

        let stopped = stoppedSnapshot(from: snapshot, now: now)
        try writeSnapshot(stopped)
        return stopped
    }

    private func stoppedSnapshot(
        from snapshot: MCPServerStatusSnapshot,
        now: Date
    ) -> MCPServerStatusSnapshot {
        return MCPServerStatusSnapshot(
            state: .stopped,
            transportMode: snapshot.transportMode,
            recentActions: snapshot.recentActions,
            updatedAt: now
        )
    }

    public func writeSnapshot(_ snapshot: MCPServerStatusSnapshot) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    private static func isProcessRunning(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        if kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func processLooksLikeGargantuaMCP(_ processID: Int32) -> Bool {
        guard let path = processPath(for: processID) else { return false }
        return URL(fileURLWithPath: path).lastPathComponent == "GargantuaMCP"
    }

    private static func processPath(for processID: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let result = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public enum MCPServerControlError: Error, LocalizedError, Sendable {
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let message): return message
        }
    }
}
