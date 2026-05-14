import Foundation

/// Top-level result of an organizer scan. Owns the list of suggested
/// `OrganizationPlan`s for a single source folder (Downloads, Desktop,
/// Screenshots, ...). Producers (`CloudAIService` extension, local rule
/// engine) build this; the staged-preview view consumes it; the move
/// executor only acts after `validate()` returns success.
public struct OrganizationProposal: Identifiable, Sendable, Codable, Equatable, Hashable {
    public let id: UUID
    /// Absolute URL of the folder that was scanned. All `MoveAction`
    /// sources AND destinations must resolve to a descendant of this URL.
    public let sourceFolder: URL
    public let generatedAt: Date
    public let backend: ProposalBackend
    public let plans: [OrganizationPlan]

    public init(
        id: UUID = UUID(),
        sourceFolder: URL,
        generatedAt: Date,
        backend: ProposalBackend,
        plans: [OrganizationPlan]
    ) {
        self.id = id
        self.sourceFolder = sourceFolder
        self.generatedAt = generatedAt
        self.backend = backend
        self.plans = plans
    }
}

// MARK: - Validation

extension OrganizationProposal {
    /// Reasons a proposal can fail validation. Each case names the offending
    /// move + plan so the producer can log a precise rejection.
    public enum ValidationError: Error, Equatable, Sendable {
        /// The plan name is empty or contains a path separator. Plans must
        /// describe a single subfolder under the scanned root.
        case invalidPlanName(planID: UUID, name: String)
        /// A move's source is not a descendant of `sourceFolder`. We do
        /// not move files we didn't scan.
        case sourceOutsideRoot(planID: UUID, moveID: UUID)
        /// A move's destination is not a descendant of `sourceFolder`. We
        /// never move files out of the scanned root — that would let the
        /// AI walk a file into `/System`, `/Library`, the trash, or any
        /// other folder the user didn't consent to.
        case destinationOutsideRoot(planID: UUID, moveID: UUID)
        /// A move's destination is the scanned root itself, not a
        /// subfolder. The organizer's contract is to group into new
        /// subfolders; moving a file to its own parent is a no-op or
        /// rename, neither of which we support here.
        case destinationIsRoot(planID: UUID, moveID: UUID)
        /// Source and destination resolve to the same URL.
        case sourceEqualsDestination(planID: UUID, moveID: UUID)
    }

    /// Fail-closed safety gate. Returns on success; throws the first
    /// violation otherwise. The executor MUST call this before performing
    /// any move — it's the only thing standing between a malformed AI
    /// response and the user's filesystem.
    public func validate() throws {
        let rootStandard = sourceFolder.standardizedFileURL.resolvingSymlinksInPath()

        for plan in plans {
            if plan.name.isEmpty || plan.name.contains("/") || plan.name.contains("\\") {
                throw ValidationError.invalidPlanName(planID: plan.id, name: plan.name)
            }

            for move in plan.moves {
                let src = move.sourceURL.standardizedFileURL.resolvingSymlinksInPath()
                let dst = move.destinationURL.standardizedFileURL.resolvingSymlinksInPath()

                if src == dst {
                    throw ValidationError.sourceEqualsDestination(planID: plan.id, moveID: move.id)
                }
                if !Self.isDescendant(src, of: rootStandard) {
                    throw ValidationError.sourceOutsideRoot(planID: plan.id, moveID: move.id)
                }
                if !Self.isDescendant(dst, of: rootStandard) {
                    throw ValidationError.destinationOutsideRoot(planID: plan.id, moveID: move.id)
                }
                if dst.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == rootStandard {
                    // Destination's parent IS the root → the file would
                    // be moved into the same flat folder, not grouped.
                    // The plan contract requires landing inside a
                    // subfolder named `plan.name`.
                    throw ValidationError.destinationIsRoot(planID: plan.id, moveID: move.id)
                }
            }
        }
    }

    /// True if `candidate` is a strict descendant of `root`. Both URLs
    /// must already be standardized + symlink-resolved by the caller so
    /// this stays a pure path-prefix check.
    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.path
        let candidatePath = candidate.path
        // Equal paths are not "descendants" — the root itself is not
        // inside itself. We require at least one separator + name.
        guard candidatePath != rootPath else { return false }
        // Append a "/" so `/Users/Jason/Downloads` doesn't match
        // `/Users/Jason/DownloadsExtra/foo`.
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(rootPrefix)
    }
}
