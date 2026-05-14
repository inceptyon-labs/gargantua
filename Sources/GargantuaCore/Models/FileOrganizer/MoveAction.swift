import Foundation

/// A single proposed file move inside an `OrganizationPlan`. The
/// destination is always under the same scanned root as the source — the
/// validator on `OrganizationProposal` enforces this invariant.
public struct MoveAction: Identifiable, Sendable, Codable, Equatable, Hashable {
    public let id: UUID
    public let sourceURL: URL
    public let destinationURL: URL
    /// Per-file reasoning from the AI. Optional — when nil, the row
    /// inherits the parent plan's reasoning in the staged-preview UI.
    public let perFileReasoning: String?

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        destinationURL: URL,
        perFileReasoning: String? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.perFileReasoning = perFileReasoning
    }
}
