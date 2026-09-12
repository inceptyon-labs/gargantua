import Darwin
import Foundation

/// Refuses to exec a binary that someone other than root or the current user
/// could have replaced.
///
/// Developer tools (`brew`, `npm`, `docker`, …) are resolved by absolute
/// candidate path and run as the user, so no privilege boundary is crossed
/// and a code-signature check is the wrong instrument: most of them are
/// unsigned scripts. What can be checked is whether anyone else could have
/// swapped the file. The rule is the one `sudo` applies to `secure_path` and
/// `sshd` to `StrictModes`: a regular file, owned by root or the current
/// user, not writable by group or others. Symlinks are followed, because the
/// shim in `~/.local/bin` is not what runs.
public enum ExecutableTrustPolicy {
    /// Why an executable was refused.
    public enum Violation: Error, Equatable, Sendable, LocalizedError {
        /// The path is not a regular file (directory, socket, device, …).
        case notRegularFile
        /// The file is owned by a user other than root or the current user.
        case untrustedOwner(uid: uid_t)
        /// The file's mode grants write access to group or others.
        case writableByOthers(mode: mode_t)

        public var errorDescription: String? {
            switch self {
            case .notRegularFile:
                "it is not a regular file"
            case .untrustedOwner(let uid):
                "it is owned by uid \(uid), not root or the current user"
            case .writableByOthers(let mode):
                "its mode \(String(mode, radix: 8)) lets other users write to it"
            }
        }
    }

    /// Checks `executable` against the policy, following symlinks.
    ///
    /// A path that cannot be `stat`ed is *not* a violation: the spawn that
    /// follows will fail with the kernel's own errno (`ENOENT`, `EACCES`),
    /// which callers already handle and tests already assert on. This
    /// policy only has an opinion about files that exist.
    public static func verify(_ executable: URL, currentUser: uid_t = geteuid()) throws {
        var info = stat()
        guard stat(executable.path, &info) == 0 else { return }
        try verify(info, currentUser: currentUser)
    }

    /// The policy proper, on an already-fetched `stat` record.
    static func verify(_ info: stat, currentUser: uid_t) throws {
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw Violation.notRegularFile
        }
        guard info.st_uid == 0 || info.st_uid == currentUser else {
            throw Violation.untrustedOwner(uid: info.st_uid)
        }
        guard info.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw Violation.writableByOthers(mode: info.st_mode & 0o777)
        }
    }
}
