import AppKit
import Foundation

/// Reveals trashed items in Finder for undo operations.
///
/// After a cleanup operation, the user can "undo" by revealing the
/// trashed files in Finder, where they can select and restore them.
public struct TrashRevealer: Sendable {

    public init() {}

    /// Reveal trashed items from a cleanup result.
    ///
    /// Extracts the trash URLs from succeeded items and opens Finder.
    @MainActor
    public func revealCleanupResult(_ result: CleanupResult) {
        let trashURLs = result.succeededItems.compactMap(\.trashURL)
        let validURLs = trashURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if validURLs.isEmpty {
            openTrash()
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(validURLs)
        }
    }

    /// Open the Trash folder in Finder.
    @MainActor
    public func openTrash() {
        let trashURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash")
        NSWorkspace.shared.open(trashURL)
    }
}
