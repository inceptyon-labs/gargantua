import Foundation
import SwiftData

extension PersistenceController {
    /// Record an audit entry to the SwiftData store.
    public func recordAuditEntry(_ entry: AuditEntry) throws {
        context.insert(PersistedAuditEntry(from: entry))
        try context.save()
    }

    /// Fetch audit entries within a date range.
    ///
    /// `limit` caps the number of rows returned (default 1000) so a wide
    /// date window on a populated audit log can't stall an interactive
    /// query. `offset` lets callers paginate when they need a sliding view
    /// instead of the most-recent batch.
    ///
    /// Two-phase intent+outcome pairs sharing an `id` collapse to one row,
    /// keeping the later line — the same rule `AuditWriter.readEntries()`
    /// applies to the JSONL path. Collapsing happens across the whole prefix
    /// up to the requested page's end, before `offset`/`limit` are applied, so
    /// a pair straddling a page boundary can't surface on both pages. A page
    /// whose prefix contained pairs may return fewer than `limit` rows.
    public func fetchAuditEntries(
        from startDate: Date,
        to endDate: Date = Date(),
        limit: Int = 1000,
        offset: Int = 0
    ) throws -> [AuditEntry] {
        let predicate = #Predicate<PersistedAuditEntry> {
            $0.timestamp >= startDate && $0.timestamp <= endDate
        }
        var descriptor = FetchDescriptor(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\.timestamp, order: .reverse),
                // Tiebreaker: on an exact timestamp tie SwiftData's row order is
                // arbitrary, and the collapse would otherwise be free to keep the
                // intent line. Reverse string order puts "completed" ahead of
                // "attempted" here, which the chronological flip turns into
                // "completed" winning the collapse.
                SortDescriptor(\.statusRaw, order: .reverse),
            ]
        )
        // Fetch the whole prefix up to the requested page's end, not just the
        // page: a pair's `.completed` line is newer than its `.attempted` one,
        // so it always sits at a smaller index here. Collapsing the prefix
        // therefore always sees the outcome line before the intent line it
        // supersedes. Slicing first would strand an `.attempted` row at the top
        // of the next page and report a finished operation as a crashed one.
        descriptor.fetchLimit = offset + limit
        descriptor.fetchOffset = 0
        let rows = try context.fetch(descriptor).compactMap { $0.toDomain() }
        // collapsingByID expects chronological order and keeps the last line
        // per id; the descriptor sorts newest-first, so flip in and back out.
        let collapsed = Array(AuditWriter.collapsingByID(Array(rows.reversed())).reversed())
        return Array(collapsed.dropFirst(offset).prefix(limit))
    }

    /// Purge audit entries older than the configured retention period.
    ///
    /// - Returns: The number of entries purged.
    @discardableResult
    public func purgeOldAuditEntries(retentionDays: Int? = nil) throws -> Int {
        let settings = try fetchSettings()
        let days = retentionDays ?? settings.retentionDays
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)

        let predicate = #Predicate<PersistedAuditEntry> { $0.timestamp < cutoff }
        let descriptor = FetchDescriptor(predicate: predicate)
        let old = try context.fetch(descriptor)
        let count = old.count

        for entry in old {
            context.delete(entry)
        }
        if count > 0 {
            try context.save()
        }
        return count
    }
}
