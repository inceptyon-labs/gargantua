import Foundation

/// File-organization proposer routed through the user's downloaded MLX
/// model. Reuses `CloudOrganizerProposer.buildPrompt` / `parseResponse`
/// so the model sees the same opaque per-file IDs the Cloud path does
/// and reassembly stays local — the model cannot fabricate a move target.
///
/// The MLX path is best-effort: small local models are unreliable on
/// structured JSON, so a parse failure raises
/// `MLXOrganizerError.unparseableResponse`; callers (the session state)
/// surface that as a `.failed` phase rather than crashing. The Cloud /
/// Claude Code paths remain available as more reliable alternatives.
@MainActor
public final class MLXOrganizerProposer {
    private let aiService: LocalAIService
    private let now: @MainActor () -> Date
    private let fileManager: FileManager

    public init(
        aiService: LocalAIService,
        now: @MainActor @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.aiService = aiService
        self.now = now
        self.fileManager = fileManager
    }

    public func propose(sourceFolder: URL) async throws -> OrganizationProposal {
        let listing = try CloudOrganizerProposer.listFolder(at: sourceFolder, fileManager: fileManager)
        let prompt = try CloudOrganizerProposer.buildPrompt(
            folderName: sourceFolder.lastPathComponent,
            items: listing
        )
        guard let raw = await aiService.organize(prompt: prompt) else {
            throw MLXOrganizerError.modelNotLoaded
        }
        do {
            return try CloudOrganizerProposer.parseResponse(
                text: raw,
                sourceFolder: sourceFolder,
                listing: listing,
                generatedAt: now()
            )
        } catch {
            throw MLXOrganizerError.unparseableResponse(underlying: "\(error)")
        }
    }
}

public enum MLXOrganizerError: Error, LocalizedError, Equatable {
    case modelNotLoaded
    case unparseableResponse(underlying: String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Your local MLX model isn't loaded yet. Open AI Models to download it first."
        case .unparseableResponse:
            return "The local model didn't return valid JSON. Try Cloud or Claude Code for this folder, or run on-device rules."
        }
    }
}
