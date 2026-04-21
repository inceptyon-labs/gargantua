import Foundation

/// Allow-listed scan-result filter DSL produced by natural-language search.
///
/// Every field is optional and conjunctive: non-empty lists must match at
/// least one value, while size bounds must include the item. Unknown fields in
/// AI output are ignored by `decodeAllowListed(from:)`.
public struct ScanFilterSet: Codable, Equatable, Sendable {
    public let bundleIDs: [String]
    public let pathGlobs: [String]
    public let categories: [String]
    public let minimumSize: Int64?
    public let maximumSize: Int64?
    public let safetyLevels: [SafetyLevel]

    enum CodingKeys: String, CodingKey {
        case bundleIDs = "bundle_ids"
        case pathGlobs = "path_globs"
        case categories
        case minimumSize = "minimum_size"
        case maximumSize = "maximum_size"
        case safetyLevels = "safety"
    }

    public init(
        bundleIDs: [String] = [],
        pathGlobs: [String] = [],
        categories: [String] = [],
        minimumSize: Int64? = nil,
        maximumSize: Int64? = nil,
        safetyLevels: [SafetyLevel] = []
    ) {
        self.bundleIDs = Self.cleanStrings(bundleIDs, maxCount: 12)
        self.pathGlobs = Self.cleanStrings(pathGlobs, maxCount: 12)
        self.categories = Self.cleanStrings(categories, maxCount: 12)
        self.minimumSize = minimumSize.flatMap(Self.nonNegative)
        self.maximumSize = maximumSize.flatMap(Self.nonNegative)
        self.safetyLevels = Array(safetyLevels.prefix(3))
    }

    public var isEmpty: Bool {
        bundleIDs.isEmpty
            && pathGlobs.isEmpty
            && categories.isEmpty
            && minimumSize == nil
            && maximumSize == nil
            && safetyLevels.isEmpty
    }

    public func apply(to results: [ScanResult]) -> [ScanResult] {
        guard !isEmpty else { return results }
        return results.filter(matches)
    }

    public func matches(_ result: ScanResult) -> Bool {
        if !bundleIDs.isEmpty {
            guard let bundleID = result.source.bundleID else { return false }
            let matched = bundleIDs.contains {
                $0.compare(bundleID, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            guard matched else { return false }
        }

        if !pathGlobs.isEmpty {
            guard pathGlobs.contains(where: { Self.glob($0, matches: result.path) }) else {
                return false
            }
        }

        if !categories.isEmpty {
            guard categories.contains(where: {
                $0.compare(result.category, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) else {
                return false
            }
        }

        if let minimumSize, result.size < minimumSize { return false }
        if let maximumSize, result.size > maximumSize { return false }

        if !safetyLevels.isEmpty, !safetyLevels.contains(result.safety) {
            return false
        }

        return true
    }

    /// Decode only the supported DSL keys from model output. The decoder first
    /// tries the whole string, then the first JSON object inside it, because
    /// model responses can include a short prefix despite prompting.
    public static func decodeAllowListed(from text: String) -> ScanFilterSet? {
        let candidates = [text, firstJSONObject(in: text)].compactMap { $0 }
        let decoder = JSONDecoder()

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let raw = try? decoder.decode(RawScanFilterSet.self, from: data)
            else { continue }

            let filter = ScanFilterSet(
                bundleIDs: raw.bundleIDs ?? [],
                pathGlobs: raw.pathGlobs ?? [],
                categories: raw.categories ?? [],
                minimumSize: raw.minSize ?? raw.minimumSize,
                maximumSize: raw.maxSize ?? raw.maximumSize,
                safetyLevels: (raw.safety ?? raw.safetyLevels ?? []).compactMap(SafetyLevel.init(rawValue:))
            )
            if !filter.isEmpty {
                return filter
            }
        }
        return nil
    }

    private static func cleanStrings(_ values: [String], maxCount: Int) -> [String] {
        var seen: Set<String> = []
        var cleaned: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 256 else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            cleaned.append(trimmed)
            if cleaned.count == maxCount { break }
        }
        return cleaned
    }

    private static func nonNegative(_ value: Int64) -> Int64? {
        value >= 0 ? value : nil
    }

    private static func glob(_ pattern: String, matches value: String) -> Bool {
        var escaped = NSRegularExpression.escapedPattern(for: pattern)
        escaped = escaped
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        let regex = "^\(escaped)$"
        return value.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var isEscaped = false

        var index = start
        while index < text.endIndex {
            let character = text[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

private struct RawScanFilterSet: Decodable {
    let bundleIDs: [String]?
    let pathGlobs: [String]?
    let categories: [String]?
    let minimumSize: Int64?
    let maximumSize: Int64?
    let minSize: Int64?
    let maxSize: Int64?
    let safety: [String]?
    let safetyLevels: [String]?

    enum CodingKeys: String, CodingKey {
        case bundleIDs = "bundle_ids"
        case pathGlobs = "path_globs"
        case categories
        case minimumSize = "minimum_size"
        case maximumSize = "maximum_size"
        case minSize = "min_size"
        case maxSize = "max_size"
        case safety
        case safetyLevels = "safety_levels"
    }
}
