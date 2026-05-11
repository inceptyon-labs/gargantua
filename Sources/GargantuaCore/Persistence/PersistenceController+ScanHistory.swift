import Foundation
import SwiftData

extension PersistenceController {
    /// Record a scan result for history tracking.
    public func recordScanHistory(
        category: String,
        itemCount: Int,
        totalBytes: Int64,
        bytesFreed: Int64 = 0,
        profileID: String
    ) throws {
        let record = PersistedScanHistory(
            category: category,
            itemCount: itemCount,
            totalBytes: totalBytes,
            bytesFreed: bytesFreed,
            profileID: profileID
        )
        context.insert(record)
        try context.save()
    }

    /// Fetch scan history, optionally filtered by category.
    public func fetchScanHistory(category: String? = nil, limit: Int = 50) throws -> [PersistedScanHistory] {
        var descriptor: FetchDescriptor<PersistedScanHistory>
        if let category {
            let predicate = #Predicate<PersistedScanHistory> { $0.category == category }
            descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.scanDate, order: .reverse)])
        } else {
            descriptor = FetchDescriptor(sortBy: [SortDescriptor(\.scanDate, order: .reverse)])
        }
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    /// Get the most recent scan date across all categories.
    public func lastScanDate() throws -> Date? {
        var descriptor = FetchDescriptor<PersistedScanHistory>(sortBy: [SortDescriptor(\.scanDate, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.scanDate
    }
}
