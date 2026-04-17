import Foundation

/// A single cluster of duplicate files reported by `fclones group`.
public struct FclonesDuplicateGroup: Sendable, Equatable {
    /// Sequential index assigned by the parser (0-based) in the order groups
    /// appear in fclones output. Stable within one scan, not across scans.
    public let id: Int

    /// Common size in bytes of every file in the group.
    public let fileLen: Int64

    /// Content hash fclones computed for the group. Opaque to callers.
    public let fileHash: String

    /// Absolute paths of the files that share `fileHash`.
    public let paths: [String]

    public init(id: Int, fileLen: Int64, fileHash: String, paths: [String]) {
        self.id = id
        self.fileLen = fileLen
        self.fileHash = fileHash
        self.paths = paths
    }
}

/// Parses `fclones group --format json` output into structured duplicate groups.
///
/// fclones emits a JSON object with `header` metadata and a `groups` array. Each
/// group carries a `file_len`, `file_hash`, and `files` list. The parser uses
/// snake-case key decoding and only retains groups with 2+ paths (a single-path
/// "group" is not a duplicate and would confuse the Trust Layer).
public struct FclonesOutputParser: Sendable {
    public enum ParseError: Error, LocalizedError, Sendable {
        case invalidJSON(underlying: String)

        public var errorDescription: String? {
            switch self {
            case .invalidJSON(let underlying):
                "fclones JSON output could not be parsed: \(underlying)"
            }
        }
    }

    public init() {}

    /// Parse fclones JSON output into duplicate groups.
    ///
    /// Whitespace-only input returns an empty array (fclones prints nothing when
    /// it finds no duplicates; the adapter shouldn't blow up on that).
    public func parse(_ json: String) throws -> [FclonesDuplicateGroup] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let data = trimmed.data(using: .utf8) else {
            throw ParseError.invalidJSON(underlying: "output was not valid UTF-8")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let report: RawReport
        do {
            report = try decoder.decode(RawReport.self, from: data)
        } catch {
            throw ParseError.invalidJSON(underlying: error.localizedDescription)
        }

        var result: [FclonesDuplicateGroup] = []
        for (idx, group) in report.groups.enumerated() where group.files.count >= 2 {
            result.append(
                FclonesDuplicateGroup(
                    id: idx,
                    fileLen: group.fileLen,
                    fileHash: group.fileHash,
                    paths: group.files
                )
            )
        }
        return result
    }

    // MARK: - Decoding types

    private struct RawReport: Decodable {
        let groups: [RawGroup]
    }

    private struct RawGroup: Decodable {
        let fileLen: Int64
        let fileHash: String
        let files: [String]
    }
}
