import Foundation

/// The single source of truth for which paths the root-privileged helper is
/// permitted to remove.
///
/// This type lives in `GargantuaCore` so it is compiled into **both** binaries
/// that need it: the signed `GargantuaPrivilegedHelper` (which enforces it as
/// root) and the app (which uses it at scan time to mark root-owned items that
/// are *not* covered as view-only, instead of letting the user select them and
/// discover the limit on a failed execute). One shared definition ⇒ the two can
/// never drift, and no build-time codegen is required.
///
/// This is an **allow-list**, and is deliberately *not* user-editable or driven
/// by the YAML rules: editing it would grant root the power to delete new paths,
/// which is exactly the privilege escalation the helper boundary exists to
/// prevent. (A *deny*-list — `ProtectedRootPolicy` — can safely be user-editable,
/// because it only ever restricts.) The list is hardcoded and audited; widening
/// it is a reviewed source change, never a runtime decision.
public struct PrivilegedRemovabilityPolicy: Sendable {
    public static let shared = PrivilegedRemovabilityPolicy()

    /// Recursive system roots whose descendants (and the root itself) may be
    /// removed as root. Every entry is a vetted, regenerable location drawn from
    /// `cleanup_rules/system/privileged.yaml`. See
    /// `docs/designs/2026-06-06-unified-removability.md` for the tiering rationale.
    ///
    /// Deliberately absent: `/private/var/db/diagnostics` (the live unified-
    /// logging store `logd` writes continuously) and the blanket
    /// `/private/var/folders` (active per-session temp). Those stay view-only.
    public static let subtreeRoots: [String] = [
        "/Library/Caches",
        "/Library/Logs/Adobe",
        "/Library/Logs/CreativeCloud",
        "/Library/Logs/DiagnosticReports",
        "/Library/Updates",
        "/Library/Apple/usr/share/rosetta/rosetta_update_bundle",
        "/macOS Install Data",
        "/private/tmp",
        "/private/var/tmp",
        "/private/var/log",
        "/private/var/db/powerlog",
        "/private/var/db/DiagnosticPipeline",
        "/private/var/db/reportmemoryexception/MemoryLimitViolations",
    ]

    /// Files matching a suffix under a root that is itself too broad to allow
    /// wholesale. `/private/var/folders` holds active per-session caches for
    /// running processes, so only the specific generated `*.code_sign_clone`
    /// artifacts may be removed — never the folder tree.
    public static let suffixUnderRoot: [(root: String, suffix: String)] = [
        ("/private/var/folders", ".code_sign_clone"),
    ]

    public init() {}

    /// Collapse the macOS firmlink aliases so `/private/var`, `/private/tmp`, and
    /// `/private/etc` compare equal to `/var`, `/tmp`, `/etc`.
    ///
    /// `URL.standardizedFileURL` rewrites an existing `/private/var/...` path to
    /// `/var/...`, so the candidate path the helper validates and the roots in
    /// this policy must both be normalized to one form or they never match. This
    /// is exactly why the tier-1 `/private/var/db/*` roots failed in the field
    /// while the firmlink-free `/Applications` and `/Library` roots worked.
    public static func canonical(_ path: String) -> String {
        for prefix in ["/private/var", "/private/tmp", "/private/etc"] {
            if path == prefix { return String(path.dropFirst("/private".count)) }
            if path.hasPrefix(prefix + "/") { return String(path.dropFirst("/private".count)) }
        }
        return path
    }

    /// Whether the privileged helper may remove `path`. Accepts either the
    /// `/private/var` or the canonical `/var` form (and likewise tmp/etc).
    /// `isDirectory` distinguishes the app-bundle and launch-daemon-plist rules.
    public func allows(path rawPath: String, isDirectory: Bool) -> Bool {
        let path = Self.canonical(rawPath)

        // Uninstaller scope (pre-existing behavior; these roots have no firmlink).
        if path.hasPrefix("/Applications/"), path.hasSuffix(".app"), isDirectory,
           isDirectChild(path, of: "/Applications") {
            return true
        }
        if path.hasPrefix("/Library/LaunchDaemons/"), path.hasSuffix(".plist"), !isDirectory,
           isDirectChild(path, of: "/Library/LaunchDaemons") {
            return true
        }
        if path.hasPrefix("/Library/PrivilegedHelperTools/"),
           isDirectChild(path, of: "/Library/PrivilegedHelperTools") {
            return true
        }

        // Tier-1 system roots (recursive). Roots are canonicalized too so the
        // `/private/var/...` entries match the canonical `/var/...` candidate.
        if Self.subtreeRoots.contains(where: { isInSubtree(path, root: Self.canonical($0)) }) {
            return true
        }

        // Narrow suffix-in-root carve-outs.
        if Self.suffixUnderRoot.contains(where: {
            path.hasSuffix($0.suffix) && isInSubtree(path, root: Self.canonical($0.root))
        }) {
            return true
        }

        return false
    }

    /// True when `path` is a regular file carrying more than one hard link.
    ///
    /// Such a file is unsafe for the privileged helper to remove: the move into
    /// the user's Trash preserves the inode (same volume) and the helper then
    /// `lchown`s it to the invoking user, so a second link pointing into a
    /// root-owned file — e.g. an unprivileged user hardlinking `/etc/sudoers`
    /// into world-writable `/private/tmp`, which `subtreeRoots` covers — would
    /// hand that inode's ownership to the user. The helper's symlink guard does
    /// not catch this because a hard link is not a symlink. Genuine regenerable
    /// temp/cache files have `st_nlink == 1`. Uses `lstat`, so a final symlink
    /// is inspected as the link, not its target; a missing path reads as `false`
    /// (the existence check is a separate guard).
    public func isMultiplyLinkedRegularFile(path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink > 1
    }

    private func isDirectChild(_ path: String, of parent: String) -> Bool {
        URL(fileURLWithPath: path).deletingLastPathComponent().path == parent
    }

    /// True when `path` is `root` itself or lives anywhere beneath it. Guards
    /// against the `/foo` vs `/foobar` prefix trap by requiring a `/` boundary.
    private func isInSubtree(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}
