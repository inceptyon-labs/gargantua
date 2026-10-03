import Foundation

/// The user's Settings › Exclusions, applied to scan results.
///
/// A literal pattern excludes that path, everything beneath it, and any folder
/// that contains it, since cleaning the folder would remove the excluded path
/// too. A pattern containing `*` is matched against the whole path and against
/// each of its ancestors, so `~/Library/Caches/com.acme.*` also covers files
/// inside the matching folders. Comparison ignores case, matching the default
/// case-insensitive APFS volume; the error direction is excluding too much,
/// never too little.
public struct PathExclusionMatcher: Sendable {
    public static let none = PathExclusionMatcher(patterns: [String]())

    private let literals: [String]
    private let globs: [String]

    public init(patterns: some Sequence<String>) {
        var literals: [String] = []
        var globs: [String] = []
        for raw in patterns {
            let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { continue }
            let normalized = Self.normalized(pattern)
            if normalized.contains("*") {
                globs.append(normalized)
            } else {
                literals.append(normalized)
            }
        }
        self.literals = literals
        self.globs = globs
    }

    public var isEmpty: Bool {
        literals.isEmpty && globs.isEmpty
    }

    public func excludes(_ path: String) -> Bool {
        guard !isEmpty else { return false }
        let target = Self.normalized(path)
        for literal in literals {
            if target == literal || target.hasPrefix(literal + "/") || literal.hasPrefix(target + "/") {
                return true
            }
        }
        guard !globs.isEmpty else { return false }
        var candidate = target
        while candidate.count > 1 {
            if globs.contains(where: { PathExpander.fnmatch(pattern: $0, name: candidate) }) {
                return true
            }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return false
    }

    public func filter(_ results: [ScanResult]) -> [ScanResult] {
        guard !isEmpty else { return results }
        return results.filter { !excludes($0.path) }
    }

    private static func normalized(_ path: String) -> String {
        let standardized = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        let trimmed = standardized.count > 1 && standardized.hasSuffix("/")
            ? String(standardized.dropLast())
            : standardized
        return trimmed.lowercased()
    }
}
