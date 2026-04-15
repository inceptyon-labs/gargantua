import AppKit
import Foundation

/// Reveals trashed items in Finder for undo operations.
///
/// After a cleanup operation, the user can "undo" by revealing the
/// trashed files in Finder, where they can select and restore them.
public struct TrashRevealer: Sendable {

    public init() {}

    /// Reveal the given URLs in Finder.
    ///
    /// Opens a Finder window with the specified files selected.
    /// Typically used with `CleanupItemResult.trashURL` values.
    ///
    /// - Parameter urls: File URLs to reveal (usually Trash locations).
    @MainActor
    public func revealInFinder(urls: [URL]) {
        let validURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !validURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(validURLs)
    }

    /// Reveal trashed items from a cleanup result.
    ///
    /// Extracts the trash URLs from succeeded items and opens Finder.
    @MainActor
    public func revealCleanupResult(_ result: CleanupResult) {
        let trashURLs = result.succeededItems.compactMap(\.trashURL)
        revealInFinder(urls: trashURLs)
    }

    /// Open the Trash folder in Finder.
    @MainActor
    public func openTrash() {
        let trashURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash")
        NSWorkspace.shared.open(trashURL)
    }
}
