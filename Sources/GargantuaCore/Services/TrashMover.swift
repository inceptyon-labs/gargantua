import AppKit
import Foundation

protocol TrashMoving: Sendable {
    @MainActor
    func moveToTrash(_ url: URL) async throws -> URL?
}

struct TrashMoveFailure: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

struct TrashMoveFallbackFailure: LocalizedError, Sendable {
    let primary: any Error
    let fallback: any Error

    var errorDescription: String? {
        "Trash move failed: \(primary.localizedDescription). Fallback also failed: \(fallback.localizedDescription)."
    }
}

/// Tries a primary mover, falling back to a second on failure. Both paths move
/// items to the system Trash silently — unlike driving Finder over Apple Events,
/// neither plays the per-item "move to Trash" sound, and both record the Put
/// Back metadata so the user can restore from the Trash.
final class FallbackTrashMover: TrashMoving {
    private let primary: any TrashMoving
    private let fallback: any TrashMoving

    init(
        primary: any TrashMoving = FileManagerTrashMover(),
        fallback: any TrashMoving = WorkspaceTrashMover()
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    @MainActor
    func moveToTrash(_ url: URL) async throws -> URL? {
        do {
            return try await primary.moveToTrash(url)
        } catch {
            let primaryError = error
            do {
                return try await fallback.moveToTrash(url)
            } catch {
                throw TrashMoveFallbackFailure(
                    primary: primaryError,
                    fallback: error
                )
            }
        }
    }
}

/// Primary trash path: `FileManager.trashItem` moves the item to `~/.Trash`
/// silently, records Put Back metadata, and returns the actual resulting Trash
/// URL after any name-collision rename. Needs no Automation consent and doesn't
/// depend on Finder being responsive. Runs off the main thread so a slow move
/// (e.g. a cross-volume item) doesn't stall the UI mid-clean.
final class FileManagerTrashMover: TrashMoving {
    @MainActor
    func moveToTrash(_ url: URL) async throws -> URL? {
        try await Task.detached(priority: .userInitiated) {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            return resultingURL as URL?
        }.value
    }
}

final class WorkspaceTrashMover: TrashMoving {
    @MainActor
    func moveToTrash(_ url: URL) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { trashedURLs, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: trashedURLs[url])
                }
            }
        }
    }
}
