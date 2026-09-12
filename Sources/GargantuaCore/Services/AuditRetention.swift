import Foundation

/// Applies the persisted "Audit retention" window to `audit.json`.
///
/// The purge runs at launch and again whenever the user changes the window in
/// Settings → About, so the row there describes something that actually
/// happens. Both callers route through here so the failure policy lives in
/// one place.
public enum AuditRetention {
    /// Retention windows offered in Settings, in days.
    public static let options: [Int] = [30, 90, 180, 365]

    /// Purge entries older than `retentionDays` on a background task.
    ///
    /// Off the caller's thread because the purge takes the audit lock and may
    /// rewrite the file. A failure — typically the lock held by a wedged
    /// `GargantuaMCP` — is logged and otherwise ignored: the log growing until
    /// the next attempt is not worth blocking the app over.
    public static func purgeInBackground(
        retentionDays: Int,
        writer: AuditWriter = AuditWriter(),
        now: Date = Date()
    ) {
        Task.detached(priority: .utility) {
            do {
                let purged = try writer.purgeEntries(olderThanDays: retentionDays, now: now)
                if purged > 0 {
                    FileHandle.standardError.write(
                        Data("audit retention: purged \(purged) entries older than \(retentionDays) days\n".utf8)
                    )
                }
            } catch {
                FileHandle.standardError.write(Data("audit retention purge failed: \(error)\n".utf8))
            }
        }
    }
}
