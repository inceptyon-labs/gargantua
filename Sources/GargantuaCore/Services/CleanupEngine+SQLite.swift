import Foundation

extension CleanupEngine {
    /// Removes the item at `url` with `method` (trash or delete), sidecars first
    /// when it is a SQLite database.
    @MainActor
    func removeWithSQLiteSidecars(url: URL, item: ScanResult, method: CleanupMethod) async -> CleanupItemResult {
        if let failure = await removeSQLiteSidecars(of: url, item: item, method: method) {
            return failure
        }
        return method == .trash
            ? await recycleSingle(url: url, item: item)
            : await deleteSingle(url: url, item: item)
    }

    /// Removes a database's sidecars ahead of the database itself. Returns a
    /// failed result, leaving the database in place, if any sidecar can't be
    /// removed; nil when there was nothing to do or all were removed.
    @MainActor
    func removeSQLiteSidecars(of url: URL, item: ScanResult, method: CleanupMethod) async -> CleanupItemResult? {
        guard method == .trash || method == .delete,
              SQLiteDatabaseFiles.isDatabase(url.path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            return nil
        }
        for sidecar in SQLiteDatabaseFiles.existingSidecars(of: url.path) {
            let sidecarURL = URL(fileURLWithPath: sidecar)
            let removed = method == .trash
                ? await recycleSingle(url: sidecarURL, item: item)
                : await deleteSingle(url: sidecarURL, item: item)
            if !removed.succeeded {
                return CleanupItemResult(
                    item: item,
                    succeeded: false,
                    error: "Couldn't remove \(sidecarURL.lastPathComponent): "
                        + "\(removed.error ?? "unknown error"). The database was left in place."
                )
            }
        }
        return nil
    }
}
