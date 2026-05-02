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
    let primaryError: String
    let fallbackError: String

    var errorDescription: String? {
        "Finder Automation failed: \(primaryError). Direct Trash API fallback failed: \(fallbackError)."
    }
}

final class FinderFirstTrashMover: TrashMoving {
    private let primary: any TrashMoving
    private let fallback: any TrashMoving

    init(
        primary: any TrashMoving = FinderAutomationTrashMover(),
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
            let primaryMessage = error.localizedDescription
            do {
                return try await fallback.moveToTrash(url)
            } catch {
                throw TrashMoveFallbackFailure(
                    primaryError: primaryMessage,
                    fallbackError: error.localizedDescription
                )
            }
        }
    }
}

final class FinderAutomationTrashMover: TrashMoving {
    @MainActor
    func moveToTrash(_ url: URL) async throws -> URL? {
        let path = Self.appleScriptString(url.path)
        return try await Task.detached(priority: .userInitiated) {
            let source = """
            tell application "Finder"
                delete (POSIX file \(path) as alias)
            end tell
            """
            guard let script = NSAppleScript(source: source) else {
                throw TrashMoveFailure(message: "Could not create Finder Automation script.")
            }

            var errorInfo: NSDictionary?
            _ = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                throw TrashMoveFailure(message: Self.finderErrorDescription(errorInfo))
            }

            // Finder does not reliably return the final Trash URL, especially when
            // it resolves name collisions. Preserve result shape without guessing.
            return nil
        }.value
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func finderErrorDescription(_ errorInfo: NSDictionary) -> String {
        let message = errorInfo[NSAppleScript.errorMessage] as? String
            ?? errorInfo[NSAppleScript.errorBriefMessage] as? String
            ?? "Finder Automation failed."
        if let number = errorInfo[NSAppleScript.errorNumber] as? NSNumber {
            return "\(message) (\(number.intValue))"
        }
        return message
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
