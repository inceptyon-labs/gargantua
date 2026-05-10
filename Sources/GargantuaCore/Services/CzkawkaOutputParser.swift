import Foundation

/// The Phase 2 file-health categories czkawka_cli can report on.
///
/// Each case maps to a czkawka_cli subcommand and determines how the parser
/// interprets output (flat list vs. grouped duplicates).
public enum CzkawkaCategory: String, Sendable, CaseIterable {
    case emptyFiles
    case emptyFolders
    case brokenSymlinks
    case temporaryFiles
    case bigFiles
    case similarImages
    case similarVideos
    case brokenFiles

    /// The czkawka_cli subcommand for this category.
    public var subcommand: String {
        switch self {
        case .emptyFiles: "empty-files"
        case .emptyFolders: "empty-folders"
        case .brokenSymlinks: "symlinks"
        case .temporaryFiles: "temp"
        case .bigFiles: "big"
        case .similarImages: "image"
        case .similarVideos: "video"
        case .brokenFiles: "broken"
        }
    }

    /// Whether output for this category is grouped (blank-line separated) so
    /// each path belongs to a similarity/duplicate cluster.
    public var isGrouped: Bool {
        switch self {
        case .similarImages, .similarVideos: true
        default: false
        }
    }

    /// The scan-result category string paired with findings from this category.
    public var resultCategory: String {
        switch self {
        case .emptyFiles: "empty_files"
        case .emptyFolders: "empty_folders"
        case .brokenSymlinks: "broken_symlinks"
        case .temporaryFiles: "temp_files"
        case .bigFiles: "big_files"
        case .similarImages: "similar_images"
        case .similarVideos: "similar_videos"
        case .brokenFiles: "broken_files"
        }
    }
}

/// A single path czkawka_cli reported for a given category.
public struct CzkawkaFinding: Sendable, Equatable {
    /// Absolute path to the file or folder czkawka flagged.
    public let path: String

    /// Size in bytes, when czkawka reports it (currently only `big` output).
    /// Zero means "the adapter should stat the file" — the parser is not lying
    /// about size, it just doesn't have one.
    public let reportedSize: Int64

    /// Group identifier for clustered categories (similar images/videos). Nil
    /// for flat categories so callers can distinguish "no grouping" from
    /// "grouped, this is group 0".
    public let groupID: Int?

    public init(path: String, reportedSize: Int64 = 0, groupID: Int? = nil) {
        self.path = path
        self.reportedSize = reportedSize
        self.groupID = groupID
    }
}

/// Parses czkawka_cli stdout into structured findings.
///
/// Czkawka's output differs per command — and has changed between versions —
/// so the parser deliberately avoids being clever. It extracts absolute paths
/// line-by-line, interprets blank lines as group boundaries when the category
/// is grouped, and reads the leading byte count on `big` output.
public struct CzkawkaOutputParser: Sendable {

    public init() {}

    /// Parse the raw czkawka_cli stdout for a given category.
    public func parse(_ output: String, category: CzkawkaCategory) -> [CzkawkaFinding] {
        var findings: [CzkawkaFinding] = []
        var currentGroup = 0
        var groupHasEntry = false

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                if category.isGrouped && groupHasEntry {
                    currentGroup += 1
                    groupHasEntry = false
                }
                continue
            }

            // Skip headers: separator bars ("------...") and "Found N ..." lines.
            if line.hasPrefix("-") { continue }
            if line.lowercased().hasPrefix("found ") { continue }

            if let finding = extractFinding(from: line, category: category, group: currentGroup) {
                findings.append(finding)
                groupHasEntry = true
            }
        }

        return findings
    }

    // MARK: - Private

    private func extractFinding(
        from line: String,
        category: CzkawkaCategory,
        group: Int
    ) -> CzkawkaFinding? {
        // `big` output leads each line with a byte count. Everything else emits a bare path.
        if category == .bigFiles {
            return parseBigFilesLine(line)
        }

        let unquoted = unquoteLeadingPath(line)
        let path = stripPathAnnotations(unquoted)
        guard path.hasPrefix("/") else { return nil }
        return CzkawkaFinding(
            path: path,
            reportedSize: 0,
            groupID: category.isGrouped ? group : nil
        )
    }

    /// Big-files lines come in two known shapes:
    ///   * czkawka 11+: `"137.16 MiB (143819976) - \"/path/to/file\""` — bytes
    ///     in parens, path is quoted and follows ` - `.
    ///   * legacy:      `"123456 /path"` or `"123456 B /path"` — a bare byte
    ///     count followed by the path (with optional `B` unit token).
    /// Try the czkawka 11 form first, then the legacy form.
    private func parseBigFilesLine(_ line: String) -> CzkawkaFinding? {
        if let parenStart = line.firstIndex(of: "("),
           let parenEnd = line[parenStart...].firstIndex(of: ")") {
            let inside = line[line.index(after: parenStart) ..< parenEnd]
            if let bytes = Int64(inside),
               let dashRange = line.range(of: " - ", range: parenEnd ..< line.endIndex) {
                let after = String(line[dashRange.upperBound...])
                let unquoted = unquoteLeadingPath(after)
                let path = stripPathAnnotations(unquoted)
                if path.hasPrefix("/") {
                    return CzkawkaFinding(path: path, reportedSize: bytes, groupID: nil)
                }
            }
        }

        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if let first = parts.first, let bytes = Int64(first) {
            var rest = Array(parts.dropFirst())
            if rest.first == "B" { rest.removeFirst() }
            let remainder = rest.joined(separator: " ")
            let unquoted = unquoteLeadingPath(remainder)
            let path = stripPathAnnotations(unquoted)
            guard path.hasPrefix("/") else { return nil }
            return CzkawkaFinding(path: path, reportedSize: bytes, groupID: nil)
        }

        let unquoted = unquoteLeadingPath(line)
        let path = stripPathAnnotations(unquoted)
        guard path.hasPrefix("/") else { return nil }
        return CzkawkaFinding(path: path, reportedSize: 0, groupID: nil)
    }

    /// czkawka 11+ wraps every reported path in double quotes. If the line
    /// starts with `"`, return the substring up to the next `"`; otherwise
    /// return the line unchanged so legacy unquoted output keeps parsing.
    private func unquoteLeadingPath(_ line: String) -> String {
        guard line.hasPrefix("\"") else { return line }
        let afterOpen = line.index(after: line.startIndex)
        guard let closing = line[afterOpen...].firstIndex(of: "\"") else { return line }
        return String(line[afterOpen ..< closing])
    }

    /// Strip trailing annotations some czkawka commands append after the path
    /// (e.g. similar-images writes `"/path - 1920x1080 - 2.1 MB"`, symlinks
    /// write `"/path  Destination does not exist"`).
    private func stripPathAnnotations(_ line: String) -> String {
        // First, cut at the " - " separator used by similar-images/videos.
        if let dashRange = line.range(of: " - ") {
            return String(line[..<dashRange.lowerBound])
        }
        // Next, invalid-symlinks pads path + "  reason" with two spaces.
        if let doubleSpace = line.range(of: "  ") {
            return String(line[..<doubleSpace.lowerBound])
        }
        return line
    }
}
