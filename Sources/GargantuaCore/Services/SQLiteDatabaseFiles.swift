import Foundation

/// A SQLite database is a main file plus the sidecars SQLite keeps beside it.
/// Removing the main file while its `-wal` remains lets SQLite replay that log
/// into the fresh database the owner creates next, and in WAL mode writes land
/// in the `-wal` before the main file, so the two are sized, aged and removed
/// as one item.
enum SQLiteDatabaseFiles {
    /// Filename suffixes of SQLite database files.
    static let suffixes = [".db", ".sqlite", ".sqlite3", ".vscdb"]
    /// Sidecar suffixes appended to a database's full filename.
    static let sidecarSuffixes = ["-wal", "-shm", "-journal"]

    static func isDatabase(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return suffixes.contains { lowered.hasSuffix($0) }
    }

    /// True when `path` is a sidecar whose database exists beside it as a regular
    /// file. That database's item already includes the sidecar's bytes.
    static func isSidecarOfExistingDatabase(_ path: String, fileManager: FileManager = .default) -> Bool {
        guard let suffix = sidecarSuffixes.first(where: { path.hasSuffix($0) }) else { return false }
        let databasePath = String(path.dropLast(suffix.count))
        var isDirectory: ObjCBool = false
        return isDatabase(databasePath)
            && fileManager.fileExists(atPath: databasePath, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// The sidecars of the database at `path` that exist right now.
    static func existingSidecars(of path: String, fileManager: FileManager = .default) -> [String] {
        sidecarSuffixes.map { path + $0 }.filter { fileManager.fileExists(atPath: $0) }
    }

    struct SidecarStats {
        var modifiedAt: Date?
        var accessedAt: Date?
        var bytes: Int64
    }

    /// Newest dates and total size across the sidecars that exist right now.
    static func sidecarStats(
        of path: String,
        fileManager: FileManager = .default
    ) -> SidecarStats {
        var modifiedAt: Date?
        var accessedAt: Date?
        var bytes: Int64 = 0
        for sidecar in existingSidecars(of: path, fileManager: fileManager) {
            let values = try? URL(fileURLWithPath: sidecar).resourceValues(forKeys: [
                .contentAccessDateKey,
                .contentModificationDateKey,
            ])
            let modified = values?.contentModificationDate
            modifiedAt = [modifiedAt, modified].compactMap { $0 }.max()
            accessedAt = [accessedAt, values?.contentAccessDate ?? modified].compactMap { $0 }.max()
            let attrs = try? fileManager.attributesOfItem(atPath: sidecar)
            bytes += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return SidecarStats(modifiedAt: modifiedAt, accessedAt: accessedAt, bytes: bytes)
    }
}
