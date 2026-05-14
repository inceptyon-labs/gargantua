import Foundation

/// Pure functions that build a Cloud AI prompt for a folder listing and
/// reassemble the model's JSON response into an `OrganizationProposal`.
///
/// The model never sees absolute paths — only synthetic per-file IDs +
/// filename + size + modified date. Plan reassembly looks IDs back up
/// against the local listing to produce real `MoveAction`s, so the AI
/// cannot fabricate a move targeting `/System`, `/Library`, or any other
/// path the user didn't consent to. The reassembled proposal still goes
/// through `OrganizationProposal.validate()` as a belt-and-suspenders.
public enum CloudOrganizerProposer {

    // MARK: - Folder listing

    /// One entry the Cloud AI sees. `id` is opaque to the model — we use
    /// it to look the entry back up locally when parsing the response.
    public struct FolderListingItem: Sendable, Equatable {
        public let id: String
        public let url: URL
        public let name: String
        public let sizeBytes: Int64
        public let modifiedAt: Date

        public init(id: String, url: URL, name: String, sizeBytes: Int64, modifiedAt: Date) {
            self.id = id
            self.url = url
            self.name = name
            self.sizeBytes = sizeBytes
            self.modifiedAt = modifiedAt
        }
    }

    /// Max files to send to the model in a single proposal. Sonnet's
    /// throughput on a JSON-organize task is roughly 5–10 files/sec; at
    /// 200 we stay within a ~4-minute timeout budget. Folders larger
    /// than this get truncated; the user can re-run after applying the
    /// first batch.
    public static let maxListingSize = 200

    /// Top-level files in `folder`, skipping hidden entries and
    /// subdirectories. Mirrors `LocalOrganizerProposer.listEntries`.
    /// Truncates at `maxListingSize`, sorted oldest-first so the
    /// staler clutter gets organized before the user's active work.
    public static func listFolder(
        at folder: URL,
        fileManager: FileManager = .default
    ) throws -> [FolderListingItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        let urls = try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        let unsorted: [FolderListingItem] = urls.compactMap { url -> FolderListingItem? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == false else { return nil }
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate ?? .distantPast
            return FolderListingItem(
                id: UUID().uuidString,
                url: url,
                name: url.lastPathComponent,
                sizeBytes: size,
                modifiedAt: modified
            )
        }
        // Oldest-first: stale clutter is what users actually want
        // organized; if we have to truncate, drop the newest items
        // (which are most likely active work the user wouldn't want
        // moved anyway).
        let sorted = unsorted.sorted { $0.modifiedAt < $1.modifiedAt }
        return Array(sorted.prefix(maxListingSize))
    }

    // MARK: - Prompt

    /// User-facing instruction prefix. Public so tests can assert it
    /// hasn't drifted, and so the prompt is reviewable from outside the
    /// type without round-tripping a full build.
    public static let instructionPrefix = """
    You are organizing a single folder on a user's Mac. Group the files \
    below into subfolders by topic, type, or theme — propose names a \
    human would use ("Receipts", "Photos 2024", "Installers"). \
    Skip files that are clearly active work or that don't fit a group. \
    Return strict JSON only — no prose, no markdown fences. \
    Every item_id you return MUST appear in the input. \
    Schema: {"plans":[{"name":"Folder Name","reasoning":"why these belong together","item_ids":["id1","id2"]}]}.
    """

    /// Build the prompt sent to the model. Pure — no I/O.
    public static func buildPrompt(folderName: String, items: [FolderListingItem]) throws -> String {
        let payload = items.map { item -> [String: Any] in
            [
                "id": item.id,
                "name": item.name,
                "size_bytes": item.sizeBytes,
                "modified_at": ISO8601DateFormatter().string(from: item.modifiedAt),
            ]
        }
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let jsonString = String(data: json, encoding: .utf8) else {
            throw CloudOrganizerProposerError.encodingFailed
        }
        return """
        \(instructionPrefix)

        Folder: \(folderName)
        Files:
        \(jsonString)
        """
    }

    // MARK: - Parsing

    /// Reassemble a model JSON response into a validated proposal.
    ///
    /// - Parameters:
    ///   - text: Raw model output. Extracted via `CloudAIJSONExtractor`.
    ///   - sourceFolder: Folder the listing came from. All produced
    ///     `MoveAction` destinations live under this folder.
    ///   - listing: The listing the model was given. IDs the model
    ///     returns that don't appear here are dropped silently — we'd
    ///     rather under-organize than fabricate a move.
    ///   - generatedAt: Stamp on the proposal (injectable for tests).
    public static func parseResponse(
        text: String,
        sourceFolder: URL,
        listing: [FolderListingItem],
        generatedAt: Date = Date()
    ) throws -> OrganizationProposal {
        guard let payload = CloudAIJSONExtractor.decode(OrganizerProposalPayload.self, from: text) else {
            throw CloudOrganizerProposerError.unparseableResponse
        }
        let byID = Dictionary(uniqueKeysWithValues: listing.map { ($0.id, $0) })

        let plans = payload.plans.compactMap { rawPlan -> OrganizationPlan? in
            // Empty / path-bearing names will be rejected by validate()
            // — drop them here so a single bad plan doesn't fail the
            // whole proposal.
            let trimmed = rawPlan.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\\") else { return nil }

            let moves: [MoveAction] = rawPlan.itemIDs.compactMap { id in
                guard let item = byID[id] else { return nil }
                let destination = sourceFolder
                    .appendingPathComponent(trimmed, isDirectory: true)
                    .appendingPathComponent(item.name)
                return MoveAction(
                    sourceURL: item.url,
                    destinationURL: destination,
                    perFileReasoning: nil
                )
            }
            // A plan with <2 members is more noise than value — same
            // rule as the local proposer.
            guard moves.count >= 2 else { return nil }
            return OrganizationPlan(name: trimmed, reasoning: rawPlan.reasoning, moves: moves)
        }

        let proposal = OrganizationProposal(
            sourceFolder: sourceFolder,
            generatedAt: generatedAt,
            backend: .cloud,
            plans: plans
        )
        try proposal.validate()
        return proposal
    }
}

public enum CloudOrganizerProposerError: Error, LocalizedError, Equatable {
    case encodingFailed
    case unparseableResponse

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: "Failed to encode folder listing as JSON."
        case .unparseableResponse: "Cloud AI did not return parseable JSON."
        }
    }
}
