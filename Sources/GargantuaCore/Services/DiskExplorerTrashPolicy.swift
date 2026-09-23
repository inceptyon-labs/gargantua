import AppKit
import Foundation

/// Decides which Disk Explorer items may be moved to the Trash. v1 is
/// read-only outside the user's Home folder: destructive actions are scoped
/// to `NSHomeDirectory()` and further excluded from anything mounted under
/// it (a separate volume, not actually part of Home's storage). Both the
/// list row and treemap cell consult this before showing "Move to Trash" and
/// again right before calling `NSWorkspace.shared.recycle`, so a stale menu
/// state can't smuggle a destructive action through.
enum DiskExplorerTrashPolicy {
    /// True when `path` is Home itself or anything under it, compared lexically
    /// (standardized, no symlink resolution, no filesystem access). Used for
    /// the read-only banner, which renders on every row/tile and can't afford
    /// a filesystem round-trip.
    static func isLexicallyInsideHome(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let homeComponents = URL(fileURLWithPath: home).standardizedFileURL.pathComponents
        let targetComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard targetComponents.count >= homeComponents.count else { return false }
        return Array(targetComponents.prefix(homeComponents.count)) == homeComponents
    }

    /// True only when `path` is strictly under Home (never Home itself) and no
    /// directory from just below Home down to `path` itself is a mount root.
    /// Fails closed: if a mount check can't read resource values, returns false.
    ///
    /// Starts with a lexical (standardized, unresolved) containment check with
    /// no filesystem access, so a stalled network volume outside Home can't
    /// hang a row/tile render. Only a path that passes lexically goes on to the
    /// resolved-symlink check and the mount-root walk below. Consequence: a
    /// symlink whose parent chain lies outside Home but resolves into Home
    /// (e.g. `/tmp/alias -> ~/dir`) is never trashable, even though its
    /// resolved location is inside Home. That's fail-closed and acceptable —
    /// v1 only trashes paths that read as inside Home without following links.
    static func canTrash(
        path: String,
        home: String = NSHomeDirectory(),
        isMountRoot: (URL) -> Bool? = defaultIsMountRoot
    ) -> Bool {
        let lexicalHomeComponents = URL(fileURLWithPath: home).standardizedFileURL.pathComponents
        let lexicalTargetComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard lexicalTargetComponents.count > lexicalHomeComponents.count,
              Array(lexicalTargetComponents.prefix(lexicalHomeComponents.count)) == lexicalHomeComponents else {
            return false
        }

        let homeComponents = normalizedHome(home).pathComponents
        let targetComponents = normalizedTarget(path).pathComponents
        guard targetComponents.count > homeComponents.count else { return false }
        guard Array(targetComponents.prefix(homeComponents.count)) == homeComponents else { return false }

        for count in (homeComponents.count + 1) ... targetComponents.count {
            let ancestor = url(fromComponents: Array(targetComponents.prefix(count)))
            switch isMountRoot(ancestor) {
            case .some(true), .none:
                return false
            case .some(false):
                continue
            }
        }
        return true
    }

    /// `.isVolumeKey`; nil when the resource values can't be read.
    static func defaultIsMountRoot(_ url: URL) -> Bool? {
        do {
            return try url.resourceValues(forKeys: [.isVolumeKey]).isVolume
        } catch {
            return nil
        }
    }

    /// Re-checks `canTrash` and, only if allowed, calls NSWorkspace recycle.
    /// Completion runs on the main actor with nil on success or an error (a
    /// policy refusal is an error whose localizedDescription says the item is
    /// outside the Home folder and Disk Explorer can't trash it).
    @MainActor
    static func recycle(path: String, completion: @escaping @MainActor (Error?) -> Void) {
        guard canTrash(path: path) else {
            completion(OutsideHomeError())
            return
        }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.recycle([url]) { _, error in
            Task { @MainActor in
                completion(error)
            }
        }
    }

    /// `home`, standardized and fully resolved — Home itself is never a
    /// symlink leaf we need to preserve.
    private static func normalizedHome(_ home: String) -> URL {
        URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// `path`, with only its parent directory chain resolved through
    /// symlinks; the leaf component is kept as-is. `recycle` trashes the item
    /// AT the given URL, so a symlink leaf must stay a symlink leaf — only
    /// the directories that led to it matter for the Home-containment check.
    private static func normalizedTarget(_ path: String) -> URL {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        guard standardized.pathComponents.count > 1 else {
            return standardized.resolvingSymlinksInPath()
        }
        let leaf = standardized.lastPathComponent
        let resolvedParent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        return resolvedParent.appendingPathComponent(leaf)
    }

    private static func url(fromComponents components: [String]) -> URL {
        guard let first = components.first else { return URL(fileURLWithPath: "/") }
        var result = URL(fileURLWithPath: first)
        for component in components.dropFirst() {
            result.appendPathComponent(component)
        }
        return result
    }
}

private struct OutsideHomeError: LocalizedError {
    var errorDescription: String? {
        "This item is outside the Home folder and Disk Explorer can't trash it."
    }
}
