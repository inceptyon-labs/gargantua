import Foundation

extension AuditWriter {
    /// The newest `limit` entries with this `transport`, cached against the
    /// log's mtime + size. Unlike `readEntries`, only those few entries are
    /// kept between calls, not the decoded log: the sidebar's MCP status polls
    /// this every 2 s for the life of the window.
    public func recentEntries(transport: String, limit: Int) throws -> [AuditEntry] {
        guard FileManager.default.fileExists(atPath: logFile.path) else { return [] }

        let attributes = try? FileManager.default.attributesOfItem(atPath: logFile.path)
        let modificationDate = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? NSNumber)?.uint64Value

        if let modificationDate, let size,
           let cached = recentCache.withLock({ $0 }),
           cached.modificationDate == modificationDate, cached.size == size,
           cached.transport == transport, cached.limit == limit {
            return cached.entries
        }

        let content = try String(contentsOf: logFile, encoding: .utf8)
        let decoded = content.split(separator: "\n").compactMap { line in
            try? Self.decoder.decode(AuditEntry.self, from: Data(line.utf8))
        }
        let entries = Array(
            Self.collapsingByID(decoded)
                .filter { $0.transport == transport }
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(limit)
        )

        if let modificationDate, let size {
            recentCache.withLock {
                $0 = RecentCache(
                    modificationDate: modificationDate,
                    size: size,
                    transport: transport,
                    limit: limit,
                    entries: entries
                )
            }
        }
        return entries
    }
}
