import Foundation

/// Descriptor-relative filesystem operations for the privileged helper's Trash
/// handling.
///
/// The helper runs as root and moves/removes items in and around the invoking
/// user's `~/.Trash`, directories the user (and thus any code running as them)
/// fully controls. Path-string operations there are unsafe: between a check and
/// the operation, the user can swap a directory component for a symlink or
/// replace an entry, redirecting a root-run operation onto a file outside the
/// intended tree — a local privilege escalation. Every function here opens each
/// path component with `O_NOFOLLOW` and acts relative to the opened descriptor,
/// so no swapped component can redirect the operation.
///
/// The helper deliberately does **not** transfer ownership of moved items to the
/// user: `fchown` on a moved inode is unsafe because the inode may still be
/// hard-linked to a root-owned file outside the Trash (its link count read from
/// the fd cannot prove the surviving link is inside the tree). Moved items stay
/// root-owned in the user's Trash; emptying them prompts for authorization, the
/// same as any root-owned Trash item.
///
/// Lives in `GargantuaCore` (like `PrivilegedRemovabilityPolicy`) so it is
/// compiled into the signed helper that enforces it and is unit-testable.
public enum SecureTrashFileOps {

    /// Opens the invoking user's existing `<home>/.Trash` as a pinned directory
    /// descriptor without following a symlinked `.Trash`. `home` comes from the
    /// kernel-supplied uid via `getpwuid`, and its parent (`/Users`) is root-owned
    /// and cannot be swapped by the user; `O_NOFOLLOW` closes the swap on the
    /// final `.Trash` component. Returns `-1` on any failure, including a
    /// symlinked or absent `.Trash`. The caller closes a non-negative result.
    ///
    /// The helper deliberately does **not** create `.Trash`. Creating it as root
    /// and then `fchown`ing it to the user is unsafe: an attacker can swap in a
    /// root-owned directory (via `RENAME_SWAP` around the create/open) and have
    /// root chown it to them. Every real account already has `~/.Trash` (the OS
    /// makes it on first use); if it is genuinely absent, the operation fails
    /// rather than have root fabricate a Trash.
    public static func openTrashDirectory(home: String) -> Int32 {
        let homeFd = open(home, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard homeFd >= 0 else { return -1 }
        defer { close(homeFd) }
        return openat(homeFd, ".Trash", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    /// Walks an absolute path from the root, opening each component with
    /// `O_NOFOLLOW | O_DIRECTORY`, and returns the descriptor of the final
    /// directory (or `-1`). Because no component is ever followed as a symlink,
    /// an attacker who controls an intermediate component (e.g. under
    /// world-writable `/private/tmp`) cannot swap it for a symlink to redirect
    /// the resolution. `path` must be absolute and firmlink-resolved to its real
    /// `/private/...` form (macOS's `/tmp`, `/var`, `/etc` are themselves
    /// symlinks, which `O_NOFOLLOW` would otherwise reject). The caller closes a
    /// non-negative result.
    public static func openDirectoryNoFollow(path: String) -> Int32 {
        // Absolute paths only: the walk starts at "/", so a relative or empty
        // path would silently resolve against the root.
        guard path.hasPrefix("/") else { return -1 }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        for component in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            guard isSafeComponent(component) else { close(fd); return -1 }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { return -1 }
            fd = next
        }
        return fd
    }

    /// Atomically moves `leaf` from `sourceParentFd` into `trashFd`, choosing a
    /// non-colliding name derived from `leaf`. Uses `renameatx_np` with
    /// `RENAME_EXCL` so the move fails rather than overwrites if the chosen name
    /// appears concurrently, retrying with a numbered variant. Returns the final
    /// name in the Trash, or `nil` on failure. `leaf` must be a single path
    /// component.
    public static func moveIntoTrash(sourceParentFd: Int32, leaf: String, trashFd: Int32) -> String? {
        guard isSafeComponent(leaf) else { return nil }
        let asURL = URL(fileURLWithPath: leaf)
        let base = asURL.deletingPathExtension().lastPathComponent
        let ext = asURL.pathExtension

        var index = 0
        while index < 100_000 {
            let candidate: String
            if index == 0 {
                candidate = leaf
            } else if ext.isEmpty {
                candidate = "\(base) \(index)"
            } else {
                candidate = "\(base) \(index).\(ext)"
            }
            let result = leaf.withCString { from in
                candidate.withCString { to in
                    renameatx_np(sourceParentFd, from, trashFd, to, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 { return candidate }
            // Only a name collision is worth another attempt; any other errno is
            // a real failure (missing source, cross-device, permission).
            if errno != EEXIST { return nil }
            index += 1
        }
        return nil
    }

    /// Recursively removes `name` (a direct child of `dirFd`) using `O_NOFOLLOW`
    /// `openat` for descent and `unlinkat` for removal, never following a
    /// symlink component. A symlink entry is unlinked as the link itself.
    /// Returns `false` if the top-level entry could not be removed. `name` must
    /// be a single path component.
    @discardableResult
    public static func removeTree(inDirFd dirFd: Int32, name: String) -> Bool {
        guard isSafeComponent(name) else { return false }
        var info = stat()
        guard fstatat(dirFd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            return false
        }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            let fd = openat(dirFd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0, let dir = fdopendir(fd) {
                let childDirFd = dirfd(dir)
                while let entry = readdir(dir) {
                    let child = entryName(entry)
                    if child == "." || child == ".." { continue }
                    _ = removeTree(inDirFd: childDirFd, name: child)
                }
                closedir(dir)
            } else if fd >= 0 {
                close(fd)
            }
            return unlinkat(dirFd, name, AT_REMOVEDIR) == 0
        }
        return unlinkat(dirFd, name, 0) == 0
    }

    /// A name is a single, benign path component: non-empty, not `.`/`..`, and
    /// free of `/` and embedded NUL. Guards the utility boundary so an absolute
    /// or `../…` name can't escape the descriptor it is resolved against.
    private static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.utf8.contains(0)
    }

    /// Reads a `dirent`'s NUL-terminated `d_name` into a String.
    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        var record = entry.pointee
        return withUnsafeBytes(of: &record.d_name) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }
}
