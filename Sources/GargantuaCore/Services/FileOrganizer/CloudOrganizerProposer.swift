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

    /// Max files included in the local listing. The cluster-summary
    /// prompt compresses 100s of files into ~10 clusters in the actual
    /// AI request, so this cap is now a safety belt against truly
    /// pathological folders rather than a latency dial.
    public static let maxListingSize = 2_000

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
    You are labeling clusters of files I've already grouped for you. \
    For each cluster, propose a folder name a human would use \
    ("Receipts", "Photos 2024", "Installers") and one short reasoning \
    line. Use the sample filenames as evidence — for example, a \
    "documents" cluster whose samples all look like invoices should be \
    named "Invoices", not the generic "Documents". Skip a cluster \
    (omit it from your reply) if its samples don't suggest a coherent \
    name. Return strict JSON only — no prose, no markdown fences. \
    Schema: {"plans":[{"cluster_id":"C1","name":"Folder Name","reasoning":"..."}]}.
    """

    /// Build the prompt sent to the model. Pure — no I/O.
    ///
    /// Sends cluster summaries (id, count, total bytes, sample names)
    /// instead of every file's full record. Shrinks a 400-file folder
    /// from ~47 KB down to ~2 KB and lets the AI focus on naming,
    /// which is what it's actually good at.
    public static func buildPrompt(folderName: String, clusters: [OrganizerCluster]) -> String {
        let body = clusters.map(Self.render(cluster:)).joined(separator: "\n\n")
        return """
        \(instructionPrefix)

        Folder: \(folderName)

        \(body)
        """
    }

    private static func render(cluster: OrganizerCluster) -> String {
        let totalSize = ByteCountFormatter.string(fromByteCount: cluster.totalBytes, countStyle: .file)
        let samples = cluster.sampleNames(limit: 10)
            .map { "  - \($0)" }
            .joined(separator: "\n")
        let remaining = cluster.items.count - min(10, cluster.items.count)
        let remainingLine = remaining > 0 ? "\n  [\(remaining) more]" : ""
        return """
        Cluster \(cluster.id) (\(cluster.items.count) files, \(totalSize), inferred type: \(cluster.inferredType)):
        \(samples)\(remainingLine)
        """
    }

    // MARK: - Parsing

    /// Reassemble a model JSON response into a validated proposal.
    ///
    /// - Parameters:
    ///   - text: Raw model output. Extracted via `CloudAIJSONExtractor`.
    ///   - sourceFolder: Folder the listing came from. All produced
    ///     `MoveAction` destinations live under this folder.
    ///   - clusters: The clusters the model was given. The AI returns a
    ///     name + reasoning per cluster_id and this method reassembles
    ///     MoveActions from each matched cluster's full file list. A
    ///     cluster_id the AI returns that doesn't appear here is dropped
    ///     silently — we'd rather under-organize than fabricate a move.
    ///   - backend: Which engine produced this proposal (.cloud or .local).
    ///   - generatedAt: Stamp on the proposal (injectable for tests).
    public static func parseResponse(
        text: String,
        sourceFolder: URL,
        clusters: [OrganizerCluster],
        backend: ProposalBackend = .cloud,
        generatedAt: Date = Date()
    ) throws -> OrganizationProposal {
        guard let payload = CloudAIJSONExtractor.decode(OrganizerProposalPayload.self, from: text) else {
            throw CloudOrganizerProposerError.unparseableResponse
        }
        let byID = Dictionary(uniqueKeysWithValues: clusters.map { ($0.id, $0) })

        let plans = payload.plans.compactMap { rawPlan -> OrganizationPlan? in
            // Empty / path-bearing names will be rejected by validate()
            // — drop them here so a single bad plan doesn't fail the
            // whole proposal.
            let trimmed = rawPlan.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\\") else { return nil }
            guard let cluster = byID[rawPlan.clusterID] else { return nil }

            let moves: [MoveAction] = cluster.items.map { item in
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
            backend: backend,
            plans: plans
        )
        try proposal.validate()
        return proposal
    }
}

public enum CloudOrganizerProposerError: Error, LocalizedError, Equatable {
    case unparseableResponse

    public var errorDescription: String? {
        switch self {
        case .unparseableResponse: "Cloud AI did not return parseable JSON."
        }
    }
}
