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
