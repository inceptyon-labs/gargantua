import Darwin
import Foundation

/// Deleting trees whose directories the user owns but has made read-only.
///
/// Go's module cache marks every module directory 0555 so builds can't change
/// downloaded sources. `FileManager.removeItem` then fails with EACCES on the
/// first file it tries to unlink inside one, after it has already removed
/// whatever was writable. The user owns all of it, so root isn't needed, and
/// the privileged helper's allow-list rejects home paths anyway. Restoring
/// owner access on the directories, as `go clean -modcache` does, lets the
/// delete finish.
extension CleanupEngine {
    /// `FileManager.removeItem`, retried once after restoring owner access on
    /// the tree's directories when the first attempt fails with EACCES. EPERM
    /// (root ownership, SIP, an immutable flag) is left alone: a mode change
    /// can't fix it, and it escalates to the privileged helper as before.
    static func removeItemRestoringOwnerAccess(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch where isAccessDenied(error) {
            restoreOwnerAccessOnDirectories(under: url.path)
            try FileManager.default.removeItem(at: url)
        }
    }

    /// True when the error's POSIX cause is EACCES. Cocoa reports EACCES and
    /// EPERM with the same `NSFileWriteNoPermissionError` code and message, so
    /// only the underlying error tells them apart.
    static func isAccessDenied(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return nsError.code == Int(EACCES) }
        guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EACCES)
    }

    /// Adds owner read, write and search to every directory under `root` that
    /// the current user owns, parents before children so a directory that
    /// couldn't be listed can be once it is opened up. Symlinks are never
    /// followed: entries are inspected with `lstat` and changed with
    /// `AT_SYMLINK_NOFOLLOW`. Best effort; whatever it can't change is left
    /// for the retried delete to report.
    static func restoreOwnerAccessOnDirectories(under root: String) {
        let uid = getuid()
        let ownerAccess = mode_t(S_IRWXU)
        var pending = [root]
        while let path = pending.popLast() {
            var info = stat()
            guard lstat(path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == uid
            else { continue }
            if info.st_mode & ownerAccess != ownerAccess {
                _ = fchmodat(AT_FDCWD, path, (info.st_mode & 0o7777) | ownerAccess, AT_SYMLINK_NOFOLLOW)
            }
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
            pending.append(contentsOf: children.map { (path as NSString).appendingPathComponent($0) })
        }
    }
}
