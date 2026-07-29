import Foundation
import SwiftData

extension PersistenceController {
    /// Record an audit entry to the SwiftData store, upserting on `id`.
    ///
    /// A destructive operation records an `.attempted` entry before it acts and
    /// a `.completed` entry after, both carrying the same `id`. The store keeps
    /// one row per operation and the later entry overwrites the earlier one, so
    /// callers never see a two-phase pair as two rows. An operation whose
    /// process died mid-act leaves its row at `.attempted` — that surviving
    /// intent record is the forensic signal, and nothing overwrites it.
    ///
    /// Recording an `.attempted` entry for an id already stored as `.completed`
    /// is a no-op: the outcome is terminal, so a reused id can't downgrade a
    /// finished operation into a false crash record.
    ///
    /// The JSONL log written by `AuditWriter` stays append-only: it cannot
    /// safely rewrite a line mid-crash, so it collapses pairs on read instead.
    public func recordAuditEntry(_ entry: AuditEntry) throws {
        let entryID = entry.id
        var descriptor = FetchDescriptor<PersistedAuditEntry>(
            predicate: #Predicate { $0.entryID == entryID }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            // The outcome is terminal. An `.attempted` entry arriving for an id
            // already recorded as `.completed` means the id was reused, not that
            // the finished operation restarted — overwriting would replace a real
            // forensic record with a false crash signal, so drop the write.
            guard !(existing.statusRaw == AuditEntryStatus.completed.rawValue
                && entry.status == .attempted) else { return }
            existing.update(from: entry)
        } else {
            context.insert(PersistedAuditEntry(from: entry))
        }
        try context.save()
    }

    /// Fetch audit entries within a date range.
    ///
    /// `limit` caps the number of rows returned (default 1000) so a wide
    /// date window on a populated audit log can't stall an interactive
    /// query. `offset` lets callers paginate when they need a sliding view
    /// instead of the most-recent batch.
    ///
    /// The store holds one row per operation — `recordAuditEntry` upserts on
    /// `id` — so pagination here is exact: no pair-collapsing happens on read,
    /// and every page returns exactly `limit` rows while rows remain.
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
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        return try context.fetch(descriptor).compactMap { $0.toDomain() }
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
