import Foundation
import os

/// Applies a validated `OrganizationProposal` to disk and records an
/// `UndoLedger` trail so the user can reverse the operation. Apply +
/// Undo are the only two state-changing entry points; the executor
/// itself is a value-type façade over `FileManager` and the ledger.
public struct OrganizerExecutor: Sendable {
    private let fileManager: FileManager
    private let ledger: UndoLedger
    private let now: @Sendable () -> Date

    public init(
        fileManager: FileManager = .default,
        ledger: UndoLedger = UndoLedger(),
        now: @Sendable @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.ledger = ledger
        self.now = now
    }

    // MARK: - Apply

    /// Apply every move in the proposal. Refuses to start if the
    /// proposal fails `validate()`. Returns counts + per-failure detail
    /// so the UI can surface partial outcomes ("3 moved, 1 skipped").
    @discardableResult
    public func apply(_ proposal: OrganizationProposal) throws -> OrganizerExecutionResult {
        try proposal.validate()

        var succeeded: [URL] = []
        var skipped: [URL] = []
        var failed: [OrganizerMoveFailure] = []

        for plan in proposal.plans {
            for move in plan.moves {
                let outcome = applyOne(move, planID: plan.id, proposalID: proposal.id)
                switch outcome {
                case .success(let destination):
                    succeeded.append(destination)
                case .skippedMissingSource:
                    skipped.append(move.sourceURL)
                case .failure(let reason):
                    failed.append(OrganizerMoveFailure(sourceURL: move.sourceURL, reason: reason))
                }
            }
        }

        return OrganizerExecutionResult(
            proposalID: proposal.id,
            succeeded: succeeded,
            skipped: skipped,
            failed: failed
        )
    }

    private enum MoveOutcome {
        case success(URL)
        case skippedMissingSource
        case failure(String)
    }

    private func applyOne(_ move: MoveAction, planID: UUID, proposalID: UUID) -> MoveOutcome {
        guard fileManager.fileExists(atPath: move.sourceURL.path) else {
            return .skippedMissingSource
        }
        if fileManager.fileExists(atPath: move.destinationURL.path) {
            return .failure("Destination already exists: \(move.destinationURL.path)")
        }
        let parent = move.destinationURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try fileManager.moveItem(at: move.sourceURL, to: move.destinationURL)
        } catch {
            return .failure(error.localizedDescription)
        }
        let entry = UndoEntry(
            originalURL: move.sourceURL,
            appliedURL: move.destinationURL,
            appliedAt: now(),
            planID: planID,
            proposalID: proposalID
        )
        do {
            try ledger.append(entry)
        } catch {
            // The move already happened — failing to record the undo
            // entry is bad but not catastrophic. Reverse the move to
            // restore the user's pre-Apply state, then report failure.
            try? fileManager.moveItem(at: move.destinationURL, to: move.sourceURL)
            return .failure("Ledger write failed: \(error.localizedDescription)")
        }
        return .success(move.destinationURL)
    }

    // MARK: - Undo

    /// Reverse every recorded move for a proposal in LIFO order, then
    /// clear those entries from the ledger. Empty target subfolders are
    /// removed afterward on a best-effort basis.
    @discardableResult
    public func undo(proposalID: UUID) throws -> OrganizerUndoResult {
        let entries = try ledger.entries(forProposalID: proposalID)
            .sorted { $0.appliedAt > $1.appliedAt }

        var reversed: [URL] = []
        var failed: [OrganizerMoveFailure] = []
        var emptiedFolders: Set<URL> = []

        for entry in entries {
            // If the applied file is gone (user deleted it after Apply),
            // there is nothing to reverse — record as "reversed" so we
            // still clear the ledger row.
            guard fileManager.fileExists(atPath: entry.appliedURL.path) else {
                reversed.append(entry.originalURL)
                emptiedFolders.insert(entry.appliedURL.deletingLastPathComponent())
                continue
            }
            // Don't clobber: if the original slot was filled in since
            // Apply, leave it alone and report failure.
            if fileManager.fileExists(atPath: entry.originalURL.path) {
                failed.append(OrganizerMoveFailure(
                    sourceURL: entry.appliedURL,
                    reason: "Original location is no longer empty: \(entry.originalURL.path)"
                ))
                continue
            }
            do {
                let parent = entry.originalURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                try fileManager.moveItem(at: entry.appliedURL, to: entry.originalURL)
                reversed.append(entry.originalURL)
                emptiedFolders.insert(entry.appliedURL.deletingLastPathComponent())
            } catch {
                failed.append(OrganizerMoveFailure(
                    sourceURL: entry.appliedURL,
                    reason: error.localizedDescription
                ))
            }
        }

        // Best-effort cleanup: remove any subfolder that's now empty.
        // This restores the pre-Apply directory shape so a follow-up
        // re-scan doesn't see ghost folders.
        for folder in emptiedFolders {
            removeIfEmpty(folder)
        }

        if failed.isEmpty {
            try ledger.clear(proposalID: proposalID)
        }

        return OrganizerUndoResult(
            proposalID: proposalID,
            reversed: reversed,
            failed: failed
        )
    }

    private func removeIfEmpty(_ folder: URL) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        guard contents.isEmpty else { return }
        try? fileManager.removeItem(at: folder)
    }
}

// MARK: - Result types

public struct OrganizerMoveFailure: Sendable, Equatable, Hashable {
    public let sourceURL: URL
    public let reason: String

    public init(sourceURL: URL, reason: String) {
        self.sourceURL = sourceURL
        self.reason = reason
    }
}

public struct OrganizerExecutionResult: Sendable {
    public let proposalID: UUID
    public let succeeded: [URL]
    public let skipped: [URL]
    public let failed: [OrganizerMoveFailure]

    public var hasFailures: Bool { !failed.isEmpty }
    public var totalMoved: Int { succeeded.count }

    public init(
        proposalID: UUID,
        succeeded: [URL],
        skipped: [URL],
        failed: [OrganizerMoveFailure]
    ) {
        self.proposalID = proposalID
        self.succeeded = succeeded
        self.skipped = skipped
        self.failed = failed
    }
}

public struct OrganizerUndoResult: Sendable {
    public let proposalID: UUID
    public let reversed: [URL]
    public let failed: [OrganizerMoveFailure]

    public var hasFailures: Bool { !failed.isEmpty }

    public init(proposalID: UUID, reversed: [URL], failed: [OrganizerMoveFailure]) {
        self.proposalID = proposalID
        self.reversed = reversed
        self.failed = failed
    }
}
