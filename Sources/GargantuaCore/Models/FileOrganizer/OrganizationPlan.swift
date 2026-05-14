import Foundation

/// One AI-suggested grouping within an `OrganizationProposal`. Renders as
/// a single expandable row in the staged-preview UI: the `name` is the
/// proposed subfolder, `reasoning` is the AI's justification, and `moves`
/// are the individual files that would land there.
public struct OrganizationPlan: Identifiable, Sendable, Codable, Equatable, Hashable {
    public let id: UUID
    /// Display name and final subfolder name under the scanned root.
    /// Must not contain path separators — validated by
    /// `OrganizationProposal.validate()`.
    public let name: String
    /// The AI's grouping rationale. Surfaced verbatim in the UI; users
    /// can read it before clicking Apply.
    public let reasoning: String
    public let moves: [MoveAction]

    public init(
        id: UUID = UUID(),
        name: String,
        reasoning: String,
        moves: [MoveAction]
    ) {
        self.id = id
        self.name = name
        self.reasoning = reasoning
        self.moves = moves
    }
}
