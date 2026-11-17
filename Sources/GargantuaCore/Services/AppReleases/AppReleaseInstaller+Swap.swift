import Darwin
import Foundation

extension AppReleaseInstaller {
    /// Exchanges the staged bundle with the installed one in one atomic
    /// rename, so the app's path holds a complete bundle at every instant: a
    /// crash or power loss leaves either the old app or the new one there.
    /// The previous copy, now at the staged path, then goes to the Trash; if
    /// that fails the exchange is undone. Returns where it landed in the Trash.
    @MainActor
    func swapBundle(at target: URL, with staged: URL) async throws(AppReleaseInstallError) -> URL? {
        guard Self.exchange(staged, target) else {
            let code = errno
            throw code == EPERM || code == EACCES ? .appManagementDenied : .swapFailed(String(cString: strerror(code)) + ".")
        }
        do {
            return try await trash.moveToTrash(staged)
        } catch {
            guard Self.exchange(staged, target) else {
                // The update is in place. Its previous copy left the staged
                // path (a Trash move that failed late) or can't be put back.
                appReleaseInstallLogger.error(
                    "Previous copy of \(target.path, privacy: .public) not kept: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
            throw Self.isPermissionDenied(error) ? .appManagementDenied : .swapFailed(error.localizedDescription)
        }
    }

    /// `renamex_np(RENAME_SWAP)`: both paths must exist on one APFS or HFS+
    /// volume, which `onSameVolume` and the staging root under `~/Library`
    /// already require. False with `errno` set.
    private static func exchange(_ lhs: URL, _ rhs: URL) -> Bool {
        renamex_np(lhs.path, rhs.path, UInt32(RENAME_SWAP)) == 0
    }

    /// Outcome line for a swap that failed. The exchange either happens or is
    /// undone, so a failure leaves the installed copy as it was.
    static func failedSwapLine(summary: String) -> AppReleaseAuditLine {
        AppReleaseAuditLine(command: "\(summary) (failed; nothing changed)", files: [])
    }

    /// A refused Trash move is App Management (or plain file permissions)
    /// when Cocoa reports no write permission or POSIX reports `EPERM` /
    /// `EACCES`, directly or as an underlying error. A `FallbackTrashMover`
    /// failure is denied when either of its two errors is.
    static func isPermissionDenied(_ error: any Error) -> Bool {
        if let fallback = error as? TrashMoveFallbackFailure {
            return isPermissionDenied(fallback.primary) || isPermissionDenied(fallback.fallback)
        }
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 8 {
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteNoPermissionError { return true }
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    static func onSameVolume(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = try? lhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let right = try? rhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        else { return false }
        return left.isEqual(right)
    }

    /// `stagingRoot/<UUID>`, created 0700 and required not to exist yet.
    static func makeStagingDirectory(in root: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    static func removeStagingDirectory(_ directory: URL) async {
        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                appReleaseInstallLogger.error(
                    "Couldn't remove staging folder: \(error.localizedDescription, privacy: .public)"
                )
            }
        }.value
    }

    /// Removes `root/<UUID>` staging folders older than `staleStagingAge`,
    /// which a crash left behind. Entries whose names aren't UUIDs are never
    /// touched, and a folder holding a mount point (a crash can leave a disk
    /// image attached) is skipped: removing it would reach into the volume.
    static func sweepStaleStaging(in root: URL, now: Date = Date()) {
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where UUID(uuidString: name) != nil {
            let path = root.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            guard now.timeIntervalSince(modified) > staleStagingAge else { continue }
            guard !containsMountPoint(path, device: rootInfo.st_dev) else {
                appReleaseInstallLogger.notice("Left a stale staging folder with a mounted volume: \(name, privacy: .public)")
                continue
            }
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                appReleaseInstallLogger.error(
                    "Couldn't remove stale staging folder: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Whether `path` or any directory under it sits on a device other than
    /// `device`. Symlinks aren't followed. Anything unreadable counts as a
    /// mount point, so the tree is left alone.
    static func containsMountPoint(_ path: String, device: dev_t) -> Bool {
        var pending = [path]
        while let directory = pending.popLast() {
            var info = stat()
            guard lstat(directory, &info) == 0, info.st_dev == device,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: directory)
            else { return true }
            for name in names where AppBundleFiles.fileType(atPath: directory + "/" + name) == S_IFDIR {
                pending.append(directory + "/" + name)
            }
        }
        return false
    }
}
