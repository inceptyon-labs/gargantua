import Foundation

/// v1 local backend for the file organizer. Pure filename heuristics +
/// modification-date binning so the feature still works when Cloud AI is
/// disabled or no Anthropic key is configured.
///
/// Scans only the top level of `sourceFolder` — subfolders are treated
/// as already-organized and left alone. Hidden entries are skipped. The
/// proposal it returns is run through `OrganizationProposal.validate()`
/// before being handed back, so callers can move directly to apply.
public struct LocalOrganizerProposer: Sendable {
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    /// Files newer than this never appear in a plan — they're presumed
    /// active work, especially on Desktop. The cutoff is the file's
    /// modification date older than `now - recentSkipInterval`.
    private let recentSkipInterval: TimeInterval

    public init(
        fileManager: FileManager = .default,
        now: @Sendable @escaping () -> Date = Date.init,
        recentSkipInterval: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.fileManager = fileManager
        self.now = now
        self.recentSkipInterval = recentSkipInterval
    }

    public func propose(sourceFolder: URL) throws -> OrganizationProposal {
        let entries = try listEntries(at: sourceFolder)
        let cutoff = now().addingTimeInterval(-recentSkipInterval)
        let proposalID = UUID()

        var bucketed: [Category: [MoveAction]] = [:]
        for entry in entries {
            guard let bucket = categorize(entry, cutoff: cutoff) else { continue }
            let destination = sourceFolder
                .appendingPathComponent(bucket.folderName, isDirectory: true)
                .appendingPathComponent(entry.url.lastPathComponent)
            bucketed[bucket, default: []].append(
                MoveAction(
                    sourceURL: entry.url,
                    destinationURL: destination,
                    perFileReasoning: nil
                )
            )
        }

        // Drop plans with a single member — moving one file into its own
        // subfolder is more noise than value. The user can still organize
        // it manually; the organizer is for clusters.
        let plans = bucketed
            .filter { $0.value.count >= 2 }
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { entry in
                OrganizationPlan(
                    name: entry.key.folderName,
                    reasoning: entry.key.reasoning,
                    moves: entry.value
                )
            }

        let proposal = OrganizationProposal(
            id: proposalID,
            sourceFolder: sourceFolder,
            generatedAt: now(),
            backend: .local,
            plans: plans
        )
        try proposal.validate()
        return proposal
    }

    // MARK: - Listing

    private struct Entry {
        let url: URL
        let isDirectory: Bool
        let modificationDate: Date
    }

    private func listEntries(at folder: URL) throws -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .isHiddenKey]
        let urls = try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        return urls.compactMap { url -> Entry? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            // Only top-level *files* are organized. Subfolders are
            // either user-curated targets or already-organized clusters.
            guard values.isDirectory == false else { return nil }
            let modDate = values.contentModificationDate ?? .distantPast
            return Entry(url: url, isDirectory: false, modificationDate: modDate)
        }
    }

    // MARK: - Categorization

    private enum Category: Hashable {
        case screenshots
        case documents
        case images
        case videos
        case audio
        case installers
        case yearBin(Int)

        var folderName: String {
            switch self {
            case .screenshots: return "Screenshots"
            case .documents: return "Documents"
            case .images: return "Images"
            case .videos: return "Videos"
            case .audio: return "Audio"
            case .installers: return "Installers"
            case .yearBin(let year): return String(year)
            }
        }

        var reasoning: String {
            switch self {
            case .screenshots:
                return "Files matching the system Screenshot naming pattern."
            case .documents:
                return "Documents grouped by file extension (PDF, Office, plain text)."
            case .images:
                return "Image files grouped by extension."
            case .videos:
                return "Video files grouped by extension."
            case .audio:
                return "Audio files grouped by extension."
            case .installers:
                return "Installers and archives that you likely no longer need open."
            case .yearBin(let year):
                return "Older uncategorized files grouped by modification year (\(year))."
            }
        }

        var sortOrder: Int {
            switch self {
            case .screenshots: return 0
            case .documents: return 10
            case .images: return 20
            case .videos: return 30
            case .audio: return 40
            case .installers: return 50
            case .yearBin: return 100
            }
        }
    }

    private func categorize(_ entry: Entry, cutoff: Date) -> Category? {
        let name = entry.url.lastPathComponent

        // Screenshot pattern wins over extension — a screenshot is a
        // screenshot regardless of being a .png.
        let lower = name.lowercased()
        if lower.hasPrefix("screenshot") || lower.hasPrefix("screen shot") {
            return .screenshots
        }

        let ext = entry.url.pathExtension.lowercased()
        if let mapped = Self.extensionCategory[ext] {
            return mapped
        }

        // Year-bin fallback only for files older than the recent cutoff
        // — we don't want to file away something the user touched last
        // week even if we don't recognize its extension.
        guard entry.modificationDate < cutoff else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: entry.modificationDate)
        return .yearBin(year)
    }

    /// Extension → category. Conservative on purpose — anything not in
    /// this map falls through to the year-bin path (or skip if recent).
    private static let extensionCategory: [String: Category] = [
        // Documents
        "pdf": .documents, "doc": .documents, "docx": .documents,
        "xls": .documents, "xlsx": .documents,
        "ppt": .documents, "pptx": .documents,
        "txt": .documents, "md": .documents, "rtf": .documents,
        "pages": .documents, "numbers": .documents, "key": .documents,
        // Images
        "jpg": .images, "jpeg": .images, "png": .images, "heic": .images,
        "gif": .images, "webp": .images, "tiff": .images, "bmp": .images,
        "svg": .images,
        // Videos
        "mp4": .videos, "mov": .videos, "avi": .videos,
        "mkv": .videos, "m4v": .videos, "webm": .videos,
        // Audio
        "mp3": .audio, "wav": .audio, "flac": .audio,
        "aac": .audio, "m4a": .audio, "ogg": .audio,
        // Installers / archives
        "dmg": .installers, "pkg": .installers,
        "zip": .installers, "tar": .installers, "gz": .installers,
        "tgz": .installers, "bz2": .installers, "7z": .installers,
    ]
}
