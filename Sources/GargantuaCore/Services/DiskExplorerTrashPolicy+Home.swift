import Foundation

extension DiskExplorerTrashPolicy {
    /// `home`, standardized and fully resolved — Home itself is never a
    /// symlink leaf we need to preserve.
    static func normalizedHome(_ home: String) -> URL {
        URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// `path`, with only its parent directory chain resolved through
    /// symlinks; the leaf component is kept as-is. `recycle` trashes the item
    /// AT the given URL, so a symlink leaf must stay a symlink leaf — only
    /// the directories that led to it matter for the Home-containment check.
    static func normalizedTarget(_ path: String) -> URL {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        guard standardized.pathComponents.count > 1 else {
            return standardized.resolvingSymlinksInPath()
        }
        let leaf = standardized.lastPathComponent
        let resolvedParent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        return resolvedParent.appendingPathComponent(leaf)
    }

    /// Folders under Home that hold keys and credentials, relative to Home.
    /// Disk Explorer lists them (they count toward Home's size) but won't
    /// trash them, anything inside them, or a folder that contains one.
    static let homeCredentialFolders: [String] = [
        ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".config/gcloud", "Library/Keychains",
    ]
    static let credentialFolderReason = "Holds keys or credentials — Disk Explorer won't trash it"

    /// A blocked decision when the target, strictly under Home, is, is inside,
    /// or contains a credential folder; nil otherwise.
    static func credentialBlock(targetComponents: [String], homeComponents: [String]) -> DiskExplorerTrashDecision? {
        guard targetComponents.count > homeComponents.count,
              Array(targetComponents.prefix(homeComponents.count)) == homeComponents,
              touchesCredentialFolder(targetComponents: targetComponents, homeComponents: homeComponents) else {
            return nil
        }
        return .blocked(reason: credentialFolderReason)
    }

    /// `credentialBlock` on resolved paths (symlinks and firmlinks followed).
    static func credentialBlock(path: String, home: String) -> DiskExplorerTrashDecision? {
        credentialBlock(
            targetComponents: normalizedTarget(path).pathComponents,
            homeComponents: normalizedHome(home).pathComponents
        )
    }

    static func touchesCredentialFolder(targetComponents: [String], homeComponents: [String]) -> Bool {
        let relative = targetComponents.dropFirst(homeComponents.count).map { $0.lowercased() }
        return homeCredentialFolders.contains { folder in
            let parts = folder.lowercased().split(separator: "/").map(String.init)
            let shared = min(parts.count, relative.count)
            return Array(relative.prefix(shared)) == Array(parts.prefix(shared))
        }
    }
}
