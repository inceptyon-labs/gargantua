import Darwin
import Foundation

extension AppReleaseInstaller {
    /// Old bundle to the Trash, staged bundle into its place by a same-volume
    /// rename, and the old bundle back if that rename fails. Returns where the
    /// old bundle landed in the Trash.
    @MainActor
    func swapBundle(at target: URL, with staged: URL) async -> Result<URL?, AppReleaseInstallError> {
        let trashURL: URL?
        do {
            trashURL = try await trash.moveToTrash(target)
        } catch {
            guard AppReleaseVerifier.fileType(atPath: target.path) != nil else {
                return .failure(.restoreFailed(trashPath: "the Trash"))
            }
            return .failure(Self.isPermissionDenied(error) ? .appManagementDenied : .swapFailed(error.localizedDescription))
        }

        do {
            try FileManager.default.moveItem(at: staged, to: target)
            return .success(trashURL)
        } catch {
            let moveError = error.localizedDescription
            guard let trashURL else { return .failure(.restoreFailed(trashPath: "the Trash")) }
            do {
                try FileManager.default.moveItem(at: trashURL, to: target)
            } catch {
                appReleaseInstallLogger.error(
                    "Restoring \(target.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                return .failure(.restoreFailed(trashPath: trashURL.path))
            }
            return .failure(.swapFailed(moveError))
        }
    }

    /// Best-effort outcome line for a swap that failed, naming only what
    /// actually moved, so a surviving `.attempted` line keeps meaning the
    /// process died mid-operation.
    @MainActor
    func recordFailedSwap(id: UUID, appURL: URL, summary: String, error: AppReleaseInstallError) {
        let files: [AuditFile]
        let outcome: String
        if case .restoreFailed(let trashPath) = error {
            files = [AuditFile(path: appURL.path, size: 0, trashPath: trashPath)]
            outcome = "failed; previous copy left in the Trash"
        } else {
            files = []
            outcome = "failed; nothing changed"
        }
        try? auditRecorder.write(Self.pathAuditEntry(
            id: id,
            command: "\(summary) (\(outcome))",
            files: files,
            status: .completed
        ))
    }

    static func pathAuditEntry(
        id: UUID,
        command: String,
        files: [AuditFile],
        status: AuditEntryStatus
    ) -> AuditEntry {
        AuditEntry(
            id: id,
            tool: auditTool,
            command: command,
            files: files,
            safetyLevel: .review,
            confirmationMethod: .summaryDialog,
            cleanupMethod: .trash,
            bytesFreed: 0,
            status: status
        )
    }

    /// A refused Trash move is App Management (or plain file permissions)
    /// when Cocoa reports no write permission or POSIX reports `EPERM` /
    /// `EACCES`, directly or as an underlying error. `FallbackTrashMover`
    /// keeps only the messages, so its failure is classified by text the way
    /// `CleanupFailureClassifier` does for other Trash failures.
    static func isPermissionDenied(_ error: any Error) -> Bool {
        if let fallback = error as? TrashMoveFallbackFailure {
            return CleanupFailureClassifier.isElevatable(fallback.primaryError)
                || CleanupFailureClassifier.isElevatable(fallback.fallbackError)
        }
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 8 {
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteNoPermissionError { return true }
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    static func onSameVolume(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = try? lhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let right = try? rhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        else { return false }
        return left.isEqual(right)
    }

    /// `stagingRoot/<UUID>`, created 0700 and required not to exist yet.
    static func makeStagingDirectory(in root: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    static func removeStagingDirectory(_ directory: URL) async {
        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                appReleaseInstallLogger.error(
                    "Couldn't remove staging folder: \(error.localizedDescription, privacy: .public)"
                )
            }
        }.value
    }
}
