import Foundation

/// One row in the persisted undo ledger. Recorded *after* a move
/// successfully completes — failed moves never produce an entry. The
/// ledger is JSON in `~/Library/Application Support/Gargantua/` and is
/// the sole source of truth for the Undo action in the staged-preview UI.
public struct UndoEntry: Identifiable, Sendable, Codable, Equatable, Hashable {
    public let id: UUID
    public let originalURL: URL
    public let appliedURL: URL
    public let appliedAt: Date
    public let planID: UUID
    public let proposalID: UUID

    public init(
        id: UUID = UUID(),
        originalURL: URL,
        appliedURL: URL,
        appliedAt: Date,
        planID: UUID,
        proposalID: UUID
    ) {
        self.id = id
        self.originalURL = originalURL
        self.appliedURL = appliedURL
        self.appliedAt = appliedAt
        self.planID = planID
        self.proposalID = proposalID
    }
}
