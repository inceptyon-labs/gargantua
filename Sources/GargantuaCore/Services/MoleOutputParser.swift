import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "MoleOutputParser")

/// Parses JSON output from the Mole CLI into typed ScanResult arrays.
///
/// The Mole CLI (`mo scan --json`) outputs a JSON object containing an `items` array.
/// Each item is mapped to a `ScanResult` with its category determining the Trust Layer
/// safety classification.
///
/// Malformed items are skipped with a log warning — one bad item doesn't fail the parse.
public enum MoleOutputParser {

    // MARK: - Public API

    /// Parse Mole JSON output into ScanResult models.
    ///
    /// - Parameter json: Raw JSON string from `mo scan --json` stdout.
    /// - Returns: Array of successfully parsed ScanResult items.
    /// - Throws: `MoleParseError.invalidJSON` if the top-level structure is unparseable.
    public static func parse(_ json: String) throws -> [ScanResult] {
        guard let data = json.data(using: .utf8) else {
            throw MoleParseError.invalidJSON(detail: "Input is not valid UTF-8")
        }
        return try parse(data)
    }

    /// Parse Mole JSON output from raw Data.
    public static func parse(_ data: Data) throws -> [ScanResult] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let output: MoleOutput
        do {
            output = try decoder.decode(MoleOutput.self, from: data)
        } catch {
            throw MoleParseError.invalidJSON(detail: error.localizedDescription)
        }

        if output.skippedCount > 0 {
            logger.warning("Skipped \(output.skippedCount) malformed items during JSON decoding")
        }

        var results: [ScanResult] = []
        for (index, item) in output.items.enumerated() {
            do {
                let result = try convert(item)
                results.append(result)
            } catch {
                logger.warning("Skipping item at index \(index): \(error.localizedDescription, privacy: .public)")
            }
        }

        let totalItems = output.items.count + output.skippedCount
        logger.info("Parsed \(results.count)/\(totalItems) items from Mole output")
        return results
    }

    // MARK: - Category → Safety Mapping

    /// Map a Mole category string to a Trust Layer safety level.
    ///
    /// Categories are mapped conservatively — unknown categories default to `.review`.
    public static func safetyLevel(for category: String) -> SafetyLevel {
        switch category {
        // Safe: easily regenerated or non-critical
        case "browser_cache", "system_cache", "system_logs",
             "temp_files", "trash", "installers",
             "empty_files", "broken_symlinks":
            return .safe

        // Review: may contain useful data or require judgment
        case "dev_artifacts", "docker", "homebrew", "similar_images":
            return .review

        // Protected: user-created content or sensitive data
        case "browser_data":
            return .protected_

        // Unknown categories: conservative default
        default:
            logger.notice("Unknown Mole category '\(category, privacy: .public)' — defaulting to review")
            return .review
        }
    }

    // MARK: - Item Conversion

    /// Convert a single Mole output item to a ScanResult.
    private static func convert(_ item: MoleOutputItem) throws -> ScanResult {
        guard !item.path.isEmpty else {
            throw MoleParseError.missingField(field: "path", itemId: item.id)
        }

        let category = item.category ?? "unknown"
        let safety = safetyLevel(for: category)

        return ScanResult(
            id: item.id,
            name: item.name ?? nameFromPath(item.path),
            path: item.path,
            size: item.size ?? 0,
            safety: safety,
            confidence: item.confidence ?? 80,
            explanation: item.explanation ?? "Detected by Mole scanner",
            source: SourceAttribution(
                name: item.source ?? "Unknown",
                bundleID: item.sourceBundleId
            ),
            lastAccessed: item.lastAccessed,
            category: category,
            tags: item.tags ?? [],
            regenerates: item.regenerates ?? false,
            regenerateCommand: item.regenerateCommand
        )
    }

    /// Derive a display name from a file path.
    private static func nameFromPath(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - Mole JSON Schema (internal Codable types)

/// Top-level Mole scan output.
///
/// Uses lenient decoding for items: if a single item in the JSON array is malformed,
/// it's skipped rather than failing the entire parse.
struct MoleOutput: Codable {
    let items: [MoleOutputItem]
    let scanDuration: Double?
    let totalSize: Int64?
    /// Number of items that failed to decode from the JSON array.
    let skippedCount: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scanDuration = try container.decodeIfPresent(Double.self, forKey: .scanDuration)
        totalSize = try container.decodeIfPresent(Int64.self, forKey: .totalSize)

        // Decode items leniently — skip any that fail
        var itemsContainer = try container.nestedUnkeyedContainer(forKey: .items)
        var decoded: [MoleOutputItem] = []
        var skipped = 0
        while !itemsContainer.isAtEnd {
            if let item = try? itemsContainer.decode(MoleOutputItem.self) {
                decoded.append(item)
            } else {
                // Advance past the failed element
                _ = try? itemsContainer.decode(LenientSkip.self)
                skipped += 1
            }
        }
        items = decoded
        skippedCount = skipped
    }

    private enum CodingKeys: String, CodingKey {
        case items, scanDuration, totalSize
    }
}

/// Dummy type that decodes any single JSON value, used to skip malformed array elements.
private struct LenientSkip: Codable {
    init(from decoder: Decoder) throws {
        // Accept any single value to advance the unkeyed container
        _ = try? decoder.singleValueContainer().decode(String.self)
    }
}

/// A single item from Mole scan output. All fields except `id` and `path` are optional
/// to tolerate incomplete data from the CLI.
struct MoleOutputItem: Codable {
    let id: String
    let name: String?
    let path: String
    let size: Int64?
    let category: String?
    let confidence: Int?
    let explanation: String?
    let source: String?
    let sourceBundleId: String?
    let lastAccessed: Date?
    let tags: [String]?
    let regenerates: Bool?
    let regenerateCommand: String?
}

// MARK: - Parse Errors

/// Errors from parsing Mole CLI output.
public enum MoleParseError: Error, LocalizedError, Sendable {
    /// The JSON data could not be decoded.
    case invalidJSON(detail: String)
    /// A required field was missing from an item.
    case missingField(field: String, itemId: String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail):
            "Invalid Mole JSON output: \(detail)"
        case .missingField(let field, let id):
            "Item '\(id)' missing required field '\(field)'"
        }
    }
}
