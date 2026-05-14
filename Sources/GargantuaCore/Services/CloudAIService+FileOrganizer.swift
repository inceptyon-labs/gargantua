import Foundation

extension CloudAIService {

    /// Generate an `OrganizationProposal` for `sourceFolder` using the
    /// Anthropic model. Lists top-level files (skipping hidden + dirs),
    /// sends them as opaque IDs + metadata only — no file contents, no
    /// absolute paths — and reassembles the response locally so the
    /// model cannot fabricate a move target.
    ///
    /// Throws `CloudOrganizerProposerError.unparseableResponse` if the
    /// model output isn't decodable, or
    /// `OrganizationProposal.ValidationError` if any reassembled move
    /// would escape the scanned root.
    public func proposeFileOrganization(
        sourceFolder: URL
    ) async throws -> CloudOrganizerResult {
        let listing = try CloudOrganizerProposer.listFolder(at: sourceFolder, fileManager: fileManager)
        let clusters = OrganizerClusterer.cluster(listing)
        let configuration = configurationStore.load()
        let prompt = CloudOrganizerProposer.buildPrompt(
            folderName: sourceFolder.lastPathComponent,
            clusters: clusters
        )
        let completion = try await perform(
            feature: .fileOrganization,
            prompt: prompt,
            metadata: [
                "item_count": "\(listing.count)",
                "cluster_count": "\(clusters.count)",
                "folder": sourceFolder.lastPathComponent,
            ],
            configuration: configuration
        )
        let proposal = try CloudOrganizerProposer.parseResponse(
            text: completion.response.text,
            sourceFolder: sourceFolder,
            clusters: clusters,
            backend: .cloud
        )
        return CloudOrganizerResult(
            proposal: proposal,
            usageCostCents: completion.actualCostCents
        )
    }
}

/// Wrapper that pairs a Cloud-generated `OrganizationProposal` with the
/// actual cost of the call, so the UI can surface usage the same way the
/// other Cloud AI features do.
public struct CloudOrganizerResult: Sendable {
    public let proposal: OrganizationProposal
    public let usageCostCents: Int

    public init(proposal: OrganizationProposal, usageCostCents: Int) {
        self.proposal = proposal
        self.usageCostCents = usageCostCents
    }
}
