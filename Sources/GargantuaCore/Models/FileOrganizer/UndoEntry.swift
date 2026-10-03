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
    /// True when this move created `appliedURL`'s parent folder. Undo removes
    /// only folders Apply created, never one the user already had. Optional
    /// so ledger lines written before this field existed still decode.
    public let createdParentDirectory: Bool?

    public init(
        id: UUID = UUID(),
        originalURL: URL,
        appliedURL: URL,
        appliedAt: Date,
        planID: UUID,
        proposalID: UUID,
        createdParentDirectory: Bool = false
    ) {
        self.id = id
        self.originalURL = originalURL
        self.appliedURL = appliedURL
        self.appliedAt = appliedAt
        self.planID = planID
        self.proposalID = proposalID
        self.createdParentDirectory = createdParentDirectory
    }
}
