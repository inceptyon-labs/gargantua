import AppKit
import Foundation

/// Where a Disk Explorer item may go when moved to the Trash.
enum DiskExplorerTrashDecision: Equatable, Sendable {
    /// Strictly under Home, not on a separate mount — NSWorkspace recycle
    /// (keeps Finder's "Put Back").
    case home
    /// Strictly under an allow-listed location outside Home — descriptor-based
    /// move into the user's Trash; the UI asks for stronger confirmation.
    case outsideHome
    /// Not trashable; `reason` is user-facing.
    case blocked(reason: String)
}

/// Decides which Disk Explorer items may be moved to the Trash. Items under
/// `NSHomeDirectory()` go through NSWorkspace; items outside Home are only
/// trashable strictly below an allow-listed root (`/Applications`, `/Library`,
/// …), never inside a denied subtree or a protected root, and never on a
/// separate volume. Both the list row and treemap cell consult this before
/// showing "Move to Trash" and again right before moving, so a stale menu
/// state can't smuggle a destructive action through.
enum DiskExplorerTrashPolicy {
    static let outsideHomeAllowedRoots: [String] = [
        "/Applications", "/Library", "/opt", "/usr/local", "/Users/Shared", "/private/tmp",
    ]
    static let outsideHomeDeniedSubtrees: [String] = [
        "/Library/Apple", "/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/PrivilegedHelperTools",
        "/Library/Extensions", "/Library/SystemExtensions", "/Library/StagedExtensions", "/Library/Keychains",
        "/Library/Security",
    ]

    /// Protected roots loaded once, for deciding whether a row offers Move to
    /// Trash. Rows re-evaluate on every render, so re-parsing the YAML there
    /// would repeat per row; `recycle` still loads the policy fresh at confirm
    /// time, so a root added since launch is enforced even if the menu offered
    /// the item.
    static let menuProtectedRoots = ProtectedRootPolicy.loadDefault()

    static let systemLocationReason = "System location — Disk Explorer can't trash items here"
    static let separateVolumeReason = "Separate volume — Disk Explorer can't trash items here"

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

    /// Lexical-only classification of `path`: no filesystem access at all (no
    /// symlink resolution, no `.isVolumeKey` reads), so it's safe to call
    /// during view body evaluation, unlike `decision`. Strictly under Home
    /// (lexically) is `.home`; Home itself is blocked. Outside Home, defers to
    /// `outsideHomeLexicalBlockReason`. Menus use this for visibility/label;
    /// the tap handler still calls `decision` once before acting.
    static func lexicalDecision(
        path: String,
        home: String = NSHomeDirectory(),
        allowedRoots: [String] = outsideHomeAllowedRoots,
        deniedSubtrees: [String] = outsideHomeDeniedSubtrees
    ) -> DiskExplorerTrashDecision {
        let homeComponents = URL(fileURLWithPath: home).standardizedFileURL.pathComponents
        let targetComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if targetComponents.count > homeComponents.count,
           Array(targetComponents.prefix(homeComponents.count)) == homeComponents {
            return .home
        }
        if isLexicallyInsideHome(path, home: home) {
            return .blocked(reason: "This item can't be trashed from Disk Explorer")
        }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let reason = outsideHomeLexicalBlockReason(standardized, allowedRoots: allowedRoots, deniedSubtrees: deniedSubtrees) {
            return .blocked(reason: reason)
        }
        return .outsideHome
    }

    /// Classifies `path`. Inside Home (lexically) the `canTrash` rules apply.
    /// Outside Home, a cheap lexical allow-list check runs first with no
    /// filesystem access; only a path that passes goes on to parent-chain
    /// symlink resolution (leaf kept), the protected-root check, and a mount
    /// walk from just below its allowed root down to the target, failing
    /// closed when a mount check can't be read.
    static func decision(
        path: String,
        home: String = NSHomeDirectory(),
        allowedRoots: [String] = outsideHomeAllowedRoots,
        deniedSubtrees: [String] = outsideHomeDeniedSubtrees,
        protectedRoots: ProtectedRootPolicy = .loadDefault(),
        isMountRoot: (URL) -> Bool? = defaultIsMountRoot
    ) -> DiskExplorerTrashDecision {
        if isLexicallyInsideHome(path, home: home) {
            return canTrash(path: path, home: home, isMountRoot: isMountRoot)
                ? .home
                : .blocked(reason: "This item can't be trashed from Disk Explorer")
        }

        let lexical = PrivilegedRemovabilityPolicy.firmlinkResolved(URL(fileURLWithPath: path).standardizedFileURL.path)
        if let reason = outsideHomeLexicalBlockReason(lexical, allowedRoots: allowedRoots, deniedSubtrees: deniedSubtrees) {
            return .blocked(reason: reason)
        }

        let resolved = PrivilegedRemovabilityPolicy.firmlinkResolved(normalizedTarget(path).path)
        if let reason = outsideHomeLexicalBlockReason(resolved, allowedRoots: allowedRoots, deniedSubtrees: deniedSubtrees) {
            return .blocked(reason: reason)
        }
        if let reason = protectedRoots.protectionReason(
            for: URL(fileURLWithPath: resolved), homeDirectory: URL(fileURLWithPath: home)
        ) {
            return .blocked(reason: "Protected: \(reason)")
        }

        let targetComponents = URL(fileURLWithPath: resolved).pathComponents
        guard let rootComponents = allowedRootComponents(containing: targetComponents, allowedRoots: allowedRoots) else {
            return .blocked(reason: systemLocationReason)
        }
        for count in (rootComponents.count + 1) ... targetComponents.count {
            switch isMountRoot(url(fromComponents: Array(targetComponents.prefix(count)))) {
            case .some(true), .none:
                return .blocked(reason: separateVolumeReason)
            case .some(false):
                continue
            }
        }
        return .outsideHome
    }

    /// Lexical-only outside-Home check on an already standardized,
    /// firmlink-resolved absolute path: nil when `path` is strictly below one
    /// allowed root and neither inside nor containing a denied subtree,
    /// otherwise a user-facing reason. No filesystem access. Allowed roots
    /// compare case-sensitively (a miscased spelling is refused); denied
    /// subtrees compare case-insensitively (a miscased spelling still hits).
    static func outsideHomeLexicalBlockReason(
        _ path: String,
        allowedRoots: [String] = outsideHomeAllowedRoots,
        deniedSubtrees: [String] = outsideHomeDeniedSubtrees
    ) -> String? {
        let components = firmlinkResolvedComponents(path)
        guard allowedRootComponents(containing: components, allowedRoots: allowedRoots) != nil else {
            return systemLocationReason
        }
        let folded = components.map { $0.lowercased() }
        for denied in deniedSubtrees {
            let deniedFolded = firmlinkResolvedComponents(denied).map { $0.lowercased() }
            let shared = min(folded.count, deniedFolded.count)
            if Array(folded.prefix(shared)) == Array(deniedFolded.prefix(shared)) {
                return systemLocationReason
            }
        }
        return nil
    }

    /// Components of the allowed root that `components` lies strictly below, if any.
    private static func allowedRootComponents(containing components: [String], allowedRoots: [String]) -> [String]? {
        for root in allowedRoots {
            let rootComponents = firmlinkResolvedComponents(root)
            if components.count > rootComponents.count,
               Array(components.prefix(rootComponents.count)) == rootComponents {
                return rootComponents
            }
        }
        return nil
    }

    /// Standardized, then firmlink-resolved (standardizing strips `/private`).
    private static func firmlinkResolvedComponents(_ path: String) -> [String] {
        URL(fileURLWithPath: PrivilegedRemovabilityPolicy.firmlinkResolved(
            URL(fileURLWithPath: path).standardizedFileURL.path
        )).pathComponents
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
    ///
    /// Equivalent to `decision(...) == .home`; the Home-rules helper that
    /// `decision` calls for paths lexically inside Home. Views use
    /// `lexicalDecision`/`decision` directly, not this.
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

    /// Moves an `.outsideHome` item into `<home>/.Trash` relative to pinned
    /// descriptors: the parent is opened with `O_NOFOLLOW` per component, its
    /// current real path (`F_GETPATH`) is re-checked against the allow-list,
    /// and the leaf must sit on the parent's device. Success carries the final
    /// name in the Trash. The leaf itself is never followed — a symlink leaf
    /// is moved as the link.
    static func moveOutsideHomeItemToTrash(
        path: String,
        home: String = NSHomeDirectory(),
        allowedRoots: [String] = outsideHomeAllowedRoots,
        deniedSubtrees: [String] = outsideHomeDeniedSubtrees,
        protectedRoots: ProtectedRootPolicy = .loadDefault()
    ) -> Result<String, DiskExplorerTrashError> {
        switch decision(
            path: path, home: home, allowedRoots: allowedRoots,
            deniedSubtrees: deniedSubtrees, protectedRoots: protectedRoots
        ) {
        case .outsideHome:
            break
        case .home:
            return .failure(.blocked(reason: "This item is inside your Home folder"))
        case .blocked(let reason):
            return .failure(.blocked(reason: reason))
        }

        let target = URL(fileURLWithPath: PrivilegedRemovabilityPolicy.firmlinkResolved(normalizedTarget(path).path))
        let leaf = target.lastPathComponent
        let parent = PrivilegedRemovabilityPolicy.firmlinkResolved(target.deletingLastPathComponent().path)

        let parentFd = SecureTrashFileOps.openDirectoryNoFollow(path: parent)
        guard parentFd >= 0 else { return .failure(.locationChanged) }
        defer { close(parentFd) }

        guard let realTarget = pinnedTargetPath(parentFd, leaf: leaf) else { return .failure(.locationChanged) }
        if let reason = pinnedTargetBlockReason(
            realTarget, home: home, allowedRoots: allowedRoots,
            deniedSubtrees: deniedSubtrees, protectedRoots: protectedRoots
        ) {
            return .failure(.blocked(reason: reason))
        }
        if let error = leafDeviceError(parentFd, leaf: leaf) { return .failure(error) }

        let trashFd = SecureTrashFileOps.openTrashDirectory(home: home)
        guard trashFd >= 0 else { return .failure(.trashUnavailable) }
        defer { close(trashFd) }

        errno = 0
        guard let name = SecureTrashFileOps.moveIntoTrash(sourceParentFd: parentFd, leaf: leaf, trashFd: trashFd) else {
            return .failure(.moveFailed(errno: errno))
        }
        return .success(name)
    }

    /// The pinned parent's current real path (`F_GETPATH`) joined with `leaf`.
    private static func pinnedTargetPath(_ parentFd: Int32, leaf: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(parentFd, F_GETPATH, &buffer) == 0,
              let realParent = String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
            return nil
        }
        return realParent == "/" ? "/" + leaf : realParent + "/" + leaf
    }

    /// Lexical allow-list, denied-subtree, and protected-root re-check of a
    /// descriptor-derived path; nil when still allowed.
    private static func pinnedTargetBlockReason(
        _ realTarget: String,
        home: String,
        allowedRoots: [String],
        deniedSubtrees: [String],
        protectedRoots: ProtectedRootPolicy
    ) -> String? {
        if let reason = outsideHomeLexicalBlockReason(
            realTarget, allowedRoots: allowedRoots, deniedSubtrees: deniedSubtrees
        ) {
            return reason
        }
        return protectedRoots.protectionReason(
            for: URL(fileURLWithPath: realTarget), homeDirectory: URL(fileURLWithPath: home)
        ).map { "Protected: \($0)" }
    }

    /// Nil when `leaf` exists (unfollowed) on the same device as its parent.
    private static func leafDeviceError(_ parentFd: Int32, leaf: String) -> DiskExplorerTrashError? {
        var parentInfo = stat()
        var leafInfo = stat()
        guard fstat(parentFd, &parentInfo) == 0,
              fstatat(parentFd, leaf, &leafInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            return .locationChanged
        }
        return leafInfo.st_dev == parentInfo.st_dev ? nil : .blocked(reason: separateVolumeReason)
    }

    /// Re-checks `decision` and trashes accordingly: `.home` through NSWorkspace
    /// recycle, `.outsideHome` through `moveOutsideHomeItemToTrash` off the main
    /// actor, `.blocked` as an error carrying the reason. Completion runs on
    /// the main actor with nil on success or an error.
    @MainActor
    static func recycle(path: String, completion: @escaping @MainActor (Error?) -> Void) {
        switch decision(path: path) {
        case .home:
            let url = URL(fileURLWithPath: path)
            NSWorkspace.shared.recycle([url]) { _, error in
                Task { @MainActor in
                    completion(error)
                }
            }
        case .outsideHome:
            Task.detached {
                let result = moveOutsideHomeItemToTrash(path: path)
                await MainActor.run {
                    switch result {
                    case .success:
                        completion(nil)
                    case .failure(let error):
                        completion(error)
                    }
                }
            }
        case .blocked(let reason):
            completion(DiskExplorerTrashError.blocked(reason: reason))
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

enum DiskExplorerTrashError: LocalizedError, Equatable, Sendable {
    /// The policy refused the item; `reason` is user-facing.
    case blocked(reason: String)
    /// The item or a folder above it moved, vanished, or became a symbolic link.
    case locationChanged
    /// `~/.Trash` is missing or not a real folder.
    case trashUnavailable
    /// The final move failed with this `errno`.
    case moveFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .blocked(let reason):
            return reason
        case .locationChanged:
            return "The item's location changed or passes through a symbolic link, so it wasn't moved."
        case .trashUnavailable:
            return "Your Trash folder couldn't be opened."
        case .moveFailed(let code):
            switch code {
            case 0:
                return "Couldn't move this item to the Trash."
            case EXDEV:
                return "It's on a different volume than your Trash."
            case EACCES, EPERM:
                return "You don't have permission to move this item."
            default:
                return String(cString: strerror(code))
            }
        }
    }
}
