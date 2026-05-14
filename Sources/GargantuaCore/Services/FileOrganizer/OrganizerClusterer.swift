import Foundation

/// One AI-naming target. The clusterer assigns each file in the folder
/// listing to exactly one cluster; the AI then proposes a folder name +
/// reasoning per cluster, and the proposer reassembles MoveActions from
/// the cluster's full file list. The AI never echoes individual file
/// names back — it just supplies labels.
public struct OrganizerCluster: Identifiable, Sendable, Equatable {
    /// Deterministic short id ("C1", "C2", ...) used as the handle the
    /// AI returns in its response.
    public let id: String
    /// All files assigned to this cluster. Local source of truth.
    public let items: [CloudOrganizerProposer.FolderListingItem]
    /// Human-readable hint about how the cluster was formed
    /// ("images", "documents", "screenshots", "by-extension-other").
    /// Surfaced in the prompt so the AI has a starting point for naming.
    public let inferredType: String

    public init(
        id: String,
        items: [CloudOrganizerProposer.FolderListingItem],
        inferredType: String
    ) {
        self.id = id
        self.items = items
        self.inferredType = inferredType
    }

    /// Total bytes across the cluster.
    public var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Up to `limit` representative filenames — first by oldest mod
    /// date for determinism. Used in the prompt so the AI can name the
    /// cluster based on real evidence rather than just the type hint.
    public func sampleNames(limit: Int = 10) -> [String] {
        let sorted = items.sorted { $0.modifiedAt < $1.modifiedAt }
        return Array(sorted.prefix(limit)).map(\.name)
    }
}

/// Pure clustering function — groups a folder listing into clusters the
/// AI can name. Reuses the same extension map as `LocalOrganizerProposer`
/// (since "what is a PDF" doesn't need an AI to decide), then splits
/// images further into a Screenshots cluster when the system Screenshot
/// naming pattern is present.
public enum OrganizerClusterer {

    public static func cluster(
        _ items: [CloudOrganizerProposer.FolderListingItem]
    ) -> [OrganizerCluster] {
        var bucketed: [String: [CloudOrganizerProposer.FolderListingItem]] = [:]

        for item in items {
            let label = bucket(for: item)
            bucketed[label, default: []].append(item)
        }

        // Render clusters in a deterministic order so the AI sees the
        // same prompt structure across reruns. Sort by total bytes
        // descending — biggest clutter first matches the user's
        // priority when reviewing the proposal.
        let sorted = bucketed
            .map { (label: $0.key, items: $0.value) }
            .sorted { lhs, rhs in
                let lhsBytes = lhs.items.reduce(0) { $0 + $1.sizeBytes }
                let rhsBytes = rhs.items.reduce(0) { $0 + $1.sizeBytes }
                if lhsBytes != rhsBytes { return lhsBytes > rhsBytes }
                return lhs.label < rhs.label
            }

        return sorted.enumerated().map { index, entry in
            OrganizerCluster(
                id: "C\(index + 1)",
                items: entry.items,
                inferredType: entry.label
            )
        }
    }

    // MARK: - Bucketing

    private static func bucket(for item: CloudOrganizerProposer.FolderListingItem) -> String {
        let lowerName = item.name.lowercased()
        if lowerName.hasPrefix("screenshot") || lowerName.hasPrefix("screen shot") {
            return "screenshots"
        }
        let ext = (item.name as NSString).pathExtension.lowercased()
        if let category = Self.extensionCategory[ext] {
            return category
        }
        if ext.isEmpty {
            return "no-extension"
        }
        // Bucket by raw extension so unrelated rare types don't all
        // pile into one "other" cluster — gives the AI a chance to
        // label .log files as logs, .torrent files as torrents, etc.
        return "ext:\(ext)"
    }

    /// Extension → coarse category label. Same families as
    /// `LocalOrganizerProposer`; kept independent so the AI path can
    /// evolve its taxonomy without breaking the on-device rules.
    private static let extensionCategory: [String: String] = [
        // documents
        "pdf": "documents", "doc": "documents", "docx": "documents",
        "xls": "documents", "xlsx": "documents",
        "ppt": "documents", "pptx": "documents",
        "txt": "documents", "md": "documents", "rtf": "documents",
        "pages": "documents", "numbers": "documents", "key": "documents",
        // images
        "jpg": "images", "jpeg": "images", "png": "images", "heic": "images",
        "gif": "images", "webp": "images", "tiff": "images", "bmp": "images",
        "svg": "images",
        // videos
        "mp4": "videos", "mov": "videos", "avi": "videos",
        "mkv": "videos", "m4v": "videos", "webm": "videos",
        // audio
        "mp3": "audio", "wav": "audio", "flac": "audio",
        "aac": "audio", "m4a": "audio", "ogg": "audio",
        // installers / archives
        "dmg": "installers", "pkg": "installers",
        "zip": "installers", "tar": "installers", "gz": "installers",
        "tgz": "installers", "bz2": "installers", "7z": "installers",
    ]
}
