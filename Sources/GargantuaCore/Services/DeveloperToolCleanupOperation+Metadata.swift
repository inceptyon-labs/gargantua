import Foundation

extension DeveloperToolCleanupOperation {
    static let cargoPurgeTargetIDs: Set<String> = [
        "cargo-registry-src",
        "cargo-git-checkouts",
    ]

    // MARK: - Labels and copy

    public var label: String {
        switch self {
        case .homebrewCleanup: "Cleanup old versions"
        case .homebrewPruneAll: "Aggressive cache cleanup"
        case .homebrewAutoremove: "Autoremove unused dependencies"
        case .dockerImagePrune: "Prune dangling images"
        case .dockerContainerPrune: "Prune stopped containers"
        case .dockerVolumePrune: "Prune unused volumes"
        case .dockerBuilderPrune: "Prune build cache"
        case .dockerSystemPrune: "System prune"
        case .xcodeDeleteUnavailableSimulators: "Delete unavailable simulators"
        case .pnpmStorePrune: "Prune unreferenced store packages"
        case .npmCacheClean: "Clean npm cache"
        case .yarnCacheClean: "Clean Yarn cache"
        case .goCleanCache: "Clean build cache"
        case .goCleanModcache: "Clean module download cache"
        case .cargoPurgeExtractedCaches: "Purge extracted Cargo caches"
        }
    }

    public var detail: String {
        switch self {
        case .homebrewCleanup:
            "Runs Homebrew's dependency-aware cleanup for old formula versions."
        case .homebrewPruneAll:
            "Runs Homebrew cleanup with all cached downloads eligible."
        case .homebrewAutoremove:
            "Removes Homebrew dependencies no installed formula needs."
        case .dockerImagePrune:
            "Removes dangling Docker images."
        case .dockerContainerPrune:
            "Removes stopped Docker containers."
        case .dockerVolumePrune:
            "Removes Docker volumes not used by a container."
        case .dockerBuilderPrune:
            "Removes Docker builder cache."
        case .dockerSystemPrune:
            "Runs Docker's composite prune for unused images, containers, networks, and build cache."
        case .xcodeDeleteUnavailableSimulators:
            "Runs simctl's cleanup for simulator devices whose runtimes are no longer installed."
        case .pnpmStorePrune:
            "Asks pnpm to remove packages no current project store reference needs."
        case .npmCacheClean:
            "Force-clears npm's content-addressable cache. npm refetches packages from the registry on the next install."
        case .yarnCacheClean:
            "Clears Yarn's global package cache. Yarn refetches packages from the registry on the next install."
        case .goCleanCache:
            "Removes compiled package artifacts from Go's shared build cache."
        case .goCleanModcache:
            "Removes Go's shared downloaded module cache."
        case .cargoPurgeExtractedCaches:
            "Removes Cargo's extracted registry sources and git dependency checkouts from Cargo home."
        }
    }

    public var riskDetail: String? {
        switch self {
        case .dockerVolumePrune:
            "Docker volumes can hold databases, uploads, and project state that cannot be rebuilt from images."
        case .dockerSystemPrune:
            "This broad Docker prune can remove stopped-container state, untagged images, networks, and build cache; expect rebuilds or re-pulls."
        case .homebrewPruneAll:
            "This removes all cached Homebrew downloads, including files you may want offline."
        case .goCleanModcache:
            "Future Go builds may need network access to re-download modules, and offline projects can fail until dependencies are fetched again."
        case .cargoPurgeExtractedCaches:
            "Cargo will recreate these extracted sources on demand. Rebuilds may pause to unpack crates or re-check out git dependencies."
        default:
            nil
        }
    }

    public var estimateUnavailableDetail: String {
        "This command does not report an exact reclaim estimate; Gargantua records 0 bytes in the audit entry when the tool cannot provide one."
    }

    public var confirmationExplanation: String {
        [detail, riskDetail, upperBoundDetail].compactMap(\.self).joined(separator: " ")
    }

    /// `true` when the preview figure counts more than the command removes.
    /// `docker system df` reports every unused image, volume and build-cache
    /// record as reclaimable, but these prunes run without `-a`, so they
    /// remove only dangling images, anonymous volumes and dangling cache.
    public var estimateIsUpperBound: Bool {
        switch self {
        case .dockerImagePrune, .dockerVolumePrune, .dockerBuilderPrune, .dockerSystemPrune:
            true
        default:
            false
        }
    }

    private var upperBoundDetail: String? {
        guard estimateIsUpperBound else { return nil }
        return "Docker's preview counts everything unused, so this can free less than shown. " +
            "Gargantua records the amount Docker reports freeing."
    }

    public var safety: SafetyLevel {
        switch self {
        case .homebrewPruneAll, .dockerVolumePrune, .dockerSystemPrune:
            .protected_
        default:
            .review
        }
    }

    // MARK: - Command construction

    public var arguments: [String] {
        switch self {
        case .homebrewCleanup:
            ["cleanup"]
        case .homebrewPruneAll:
            ["cleanup", "--prune=all"]
        case .homebrewAutoremove:
            ["autoremove"]
        case .dockerImagePrune:
            ["image", "prune", "--force"]
        case .dockerContainerPrune:
            ["container", "prune", "--force"]
        case .dockerVolumePrune:
            ["volume", "prune", "--force"]
        case .dockerBuilderPrune:
            ["builder", "prune", "--force"]
        case .dockerSystemPrune:
            ["system", "prune", "--force"]
        case .xcodeDeleteUnavailableSimulators:
            ["simctl", "delete", "unavailable"]
        case .pnpmStorePrune:
            ["store", "prune"]
        case .npmCacheClean:
            ["cache", "clean", "--force"]
        case .yarnCacheClean:
            ["cache", "clean"]
        case .goCleanCache:
            ["clean", "-cache"]
        case .goCleanModcache:
            ["clean", "-modcache"]
        case .cargoPurgeExtractedCaches:
            ["cache", "purge-extracted"]
        }
    }

    public func commandPreview(executable: URL) -> [String] {
        [executable.path] + arguments
    }

    public var commandName: String {
        ([commandDisplayName] + arguments).joined(separator: " ")
    }

    private var commandDisplayName: String {
        switch tool {
        case .homebrew: "brew"
        case .docker: "docker"
        case .xcode: "xcrun"
        case .pnpm: "pnpm"
        case .npm: "npm"
        case .yarn: "yarn"
        case .go: "go"
        case .cargo: "cargo"
        }
    }

    // MARK: - Applicability and reclaim estimates

    public func isApplicable(to preview: DeveloperToolPreview) -> Bool {
        guard preview.tool == tool else { return false }
        switch self {
        case .homebrewCleanup:
            return preview.reclaimableBytes > 0 || !preview.items.isEmpty
        case .homebrewPruneAll, .homebrewAutoremove:
            return true
        case .dockerImagePrune, .dockerContainerPrune, .dockerVolumePrune, .dockerBuilderPrune, .dockerSystemPrune:
            return (estimatedReclaimableBytes(in: preview) ?? 0) > 0
        case .xcodeDeleteUnavailableSimulators:
            return !preview.items.isEmpty
        case .pnpmStorePrune, .npmCacheClean, .yarnCacheClean, .goCleanCache, .goCleanModcache:
            guard let id = singlePreviewItemID else { return false }
            return preview.items.contains { $0.id == id }
        case .cargoPurgeExtractedCaches:
            return preview.items.contains { Self.cargoPurgeTargetIDs.contains($0.id) }
        }
    }

    /// The single preview-item ID a package-manager cache operation acts on,
    /// shared by `isApplicable` and the reclaim-estimate lookup.
    private var singlePreviewItemID: String? {
        switch self {
        case .pnpmStorePrune: "pnpm-store"
        case .npmCacheClean: "npm-cache"
        case .yarnCacheClean: "yarn-cache"
        case .goCleanCache: "go-build-cache"
        case .goCleanModcache: "go-module-cache"
        default: nil
        }
    }

    public func estimatedReclaimableBytes(in preview: DeveloperToolPreview) -> Int64? {
        guard preview.tool == tool else { return nil }
        switch self {
        case .homebrewCleanup, .homebrewPruneAll, .homebrewAutoremove:
            return homebrewReclaimableBytes(in: preview)
        case .dockerImagePrune, .dockerContainerPrune, .dockerVolumePrune,
             .dockerBuilderPrune, .dockerSystemPrune:
            return dockerReclaimableBytes(in: preview)
        case .xcodeDeleteUnavailableSimulators, .cargoPurgeExtractedCaches:
            return previewKnownBytes(preview)
        case .pnpmStorePrune, .npmCacheClean, .yarnCacheClean, .goCleanCache, .goCleanModcache:
            return packageManagerReclaimableBytes(in: preview)
        }
    }

    private func homebrewReclaimableBytes(in preview: DeveloperToolPreview) -> Int64? {
        switch self {
        case .homebrewCleanup, .homebrewPruneAll:
            return preview.reclaimableBytes
        case .homebrewAutoremove:
            return preview.homebrewAutoremove?.totalBytes
        default:
            return nil
        }
    }

    private func dockerReclaimableBytes(in preview: DeveloperToolPreview) -> Int64? {
        switch self {
        case .dockerImagePrune:
            return dockerBytes(in: preview, titles: ["Images"])
        case .dockerContainerPrune:
            return dockerBytes(in: preview, titles: ["Containers"])
        case .dockerVolumePrune:
            return dockerBytes(in: preview, titles: ["Volumes", "Local Volumes"])
        case .dockerBuilderPrune:
            return dockerBytes(in: preview, titles: ["Build Cache"])
        case .dockerSystemPrune:
            return sumSaturating([
                dockerBytes(in: preview, titles: ["Images"]) ?? 0,
                dockerBytes(in: preview, titles: ["Containers"]) ?? 0,
                dockerBytes(in: preview, titles: ["Build Cache"]) ?? 0,
            ])
        default:
            return nil
        }
    }

    private func packageManagerReclaimableBytes(in preview: DeveloperToolPreview) -> Int64? {
        guard let id = singlePreviewItemID else { return nil }
        return previewBytes(in: preview, itemID: id)
    }

    private func dockerBytes(in preview: DeveloperToolPreview, titles: Set<String>) -> Int64? {
        preview.items.first { titles.contains($0.title) }?.reclaimableBytes
    }

    private func previewBytes(in preview: DeveloperToolPreview, itemID: String) -> Int64? {
        guard let item = preview.items.first(where: { $0.id == itemID }) else { return nil }
        return item.reclaimableBytes ?? 0
    }

    private func sumSaturating(_ values: [Int64]) -> Int64 {
        values.reduce(Int64(0)) { acc, value in
            let (sum, overflow) = acc.addingReportingOverflow(value)
            return overflow ? .max : sum
        }
    }

    private func previewKnownBytes(_ preview: DeveloperToolPreview) -> Int64? {
        let values = preview.items.compactMap(\.reclaimableBytes)
        guard !values.isEmpty else { return nil }
        return sumSaturating(values)
    }
}
