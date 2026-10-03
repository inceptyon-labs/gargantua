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

    /// For a database whose main file is already gone, removes leftover sidecars
    /// (a stray `-wal` would be replayed into the next database) unless an owner
    /// is running, then reports it already removed. `nil` when this doesn't apply.
    @MainActor
    func removeStaleSidecars(of url: URL, item: ScanResult, method: CleanupMethod) async -> CleanupItemResult? {
        guard !fileExists(url.path), SQLiteDatabaseFiles.isDatabase(url.path),
              !SQLiteDatabaseFiles.existingSidecars(of: url.path).isEmpty else { return nil }
        if let skipped = ownerRunningSkip(item: item) { return skipped }
        for sidecar in SQLiteDatabaseFiles.existingSidecars(of: url.path) {
            let sidecarURL = URL(fileURLWithPath: sidecar)
            let removed = method == .trash
                ? await recycleSingle(url: sidecarURL, item: item)
                : await deleteSingle(url: sidecarURL, item: item)
            if !removed.succeeded { return removed }
        }
        return CleanupItemResult(item: item, succeeded: true, bytesFreed: 0)
    }

    /// The skip result while any of the item's owner processes or its blocking
    /// app is running; `nil` when none is.
    func ownerRunningSkip(item: ScanResult) -> CleanupItemResult? {
        let owners = (item.ownerProcesses ?? []) + [item.blockedByApp?.bundleID].compactMap { $0 }
        guard owners.contains(where: isAppRunning) else { return nil }
        let name = item.blockedByApp?.name ?? item.source.name
        return CleanupItemResult(
            item: item,
            succeeded: false,
            error: "Skipped while \(name) is running. Quit it, then clean again."
        )
    }

    /// Removes a database's sidecars ahead of the database itself. Returns a
    /// failed result, leaving the database in place, if any sidecar can't be
    /// removed; nil when there was nothing to do or all were removed.
    @MainActor
    func removeSQLiteSidecars(of url: URL, item: ScanResult, method: CleanupMethod) async -> CleanupItemResult? {
        guard SQLiteDatabaseFiles.isDatabase(url.path),
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
