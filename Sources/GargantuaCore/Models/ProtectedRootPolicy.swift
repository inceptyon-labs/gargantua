import Foundation

/// Source of a protected-root policy entry.
public enum ProtectedRootSource: String, Codable, Sendable {
    case bundled
    case user
}

/// A filesystem root that must never be removed as a cleanup unit.
///
/// Cleanup rules identify candidates. Protected roots are the opposite:
/// global reject entries that apply to every cleanup surface, including
/// Agent Run, Deep Clean, Smart Uninstaller, and MCP clients.
public struct ProtectedRootEntry: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let reason: String
    public let source: ProtectedRootSource

    public var id: String { "\(source.rawValue):\(path)" }

    public init(path: String, reason: String, source: ProtectedRootSource = .bundled) {
        self.path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
    }
}

/// Runtime matcher for protected roots loaded from bundled policy plus any
/// user-added entries.
public struct ProtectedRootPolicy: Sendable {
    public let entries: [ProtectedRootEntry]
    private let failClosedReason: String?
    /// Entries normalized once for the current user's home, so checking a
    /// scan's results doesn't re-expand, re-standardize and re-resolve every
    /// entry for every item. Other homes (tests) are prepared per call.
    private let defaultHomePath: String
    private let preparedForDefaultHome: [PreparedEntry]

    public init(entries: [ProtectedRootEntry], failClosedReason: String? = nil) {
        self.entries = entries
        self.failClosedReason = failClosedReason
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.defaultHomePath = home.standardizedFileURL.path
        self.preparedForDefaultHome = Self.prepare(entries, homeDirectory: home)
    }

    public static func failClosed(_ reason: String) -> ProtectedRootPolicy {
        ProtectedRootPolicy(entries: [], failClosedReason: reason)
    }

    /// Load the bundled policy and merge user-added protected roots. If the
    /// bundled policy is unavailable, fail closed so cleanup cannot proceed
    /// without the global safety policy.
    public static func loadDefault(
        userStore: ProtectedRootUserStore = ProtectedRootUserStore()
    ) -> ProtectedRootPolicy {
        do {
            var policy = try ProtectedRootPolicyLoader().loadBundled()
            policy = policy.merging(userStore.loadEntries())
            return policy
        } catch {
            return .failClosed("Protected-root policy could not be loaded: \(error.localizedDescription)")
        }
    }

    public func merging(_ additionalEntries: [ProtectedRootEntry]) -> ProtectedRootPolicy {
        var seen = Set<String>()
        var merged: [ProtectedRootEntry] = []
        merged.reserveCapacity(entries.count + additionalEntries.count)

        for entry in entries + additionalEntries {
            let key = "\(entry.source.rawValue):\(entry.path)"
            guard seen.insert(key).inserted else { continue }
            merged.append(entry)
        }

        return ProtectedRootPolicy(entries: merged, failClosedReason: failClosedReason)
    }

    /// Returns a user-facing reason when `url` is a protected root. Matching
    /// is exact unless the policy entry contains `*`, in which case each `*`
    /// matches only within one path segment.
    public func protectionReason(
        for url: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        if let failClosedReason {
            return failClosedReason
        }

        let prepared = homeDirectory.standardizedFileURL.path == defaultHomePath
            ? preparedForDefaultHome
            : Self.prepare(entries, homeDirectory: homeDirectory)
        let candidates = Set([
            Self.normalizedPath(url.path, homeDirectory: homeDirectory, resolvesSymlinks: true),
            Self.normalizedPath(url.path, homeDirectory: homeDirectory, resolvesSymlinks: false),
        ])
        let foldedCandidates = Set(candidates.map { $0.lowercased() })
        let candidateComponents = candidates.map(\.pathComponentsForPolicy)
        let foldedCandidateComponents = foldedCandidates.map(\.pathComponentsForPolicy)

        // Entries whose authored spelling missed but whose case-folded
        // spelling hit — deferred to the on-disk case check below so exact
        // matches keep their attribution and the common unprotected item
        // costs no extra filesystem work.
        var caseScreened: [ScreenedEntry] = []

        for entry in prepared {
            switch Self.match(
                entry,
                candidates: candidates,
                foldedCandidates: foldedCandidates,
                candidateComponents: candidateComponents,
                foldedCandidateComponents: foldedCandidateComponents
            ) {
            case .authoredSpelling:
                return entry.reason
            case .caseFoldedOnly(let screened):
                caseScreened.append(screened)
            case .none:
                continue
            }
        }

        return Self.caseConfirmedReason(for: caseScreened, candidates: candidates)
    }

    private enum EntryMatch {
        case authoredSpelling
        case caseFoldedOnly(ScreenedEntry)
        case none
    }

    private struct ScreenedEntry {
        let reason: String
        let isGlob: Bool
        let paths: Set<String>
    }

    /// One entry with its path spellings computed for a given home directory.
    /// A glob keeps its normalized pattern and components (authored and
    /// case-folded); a literal keeps its symlink-resolved and unresolved
    /// spellings.
    private struct PreparedEntry: Sendable {
        let reason: String
        let globPattern: String?
        let globComponents: [String]
        let foldedGlobComponents: [String]
        let paths: Set<String>
        let foldedPaths: Set<String>
    }

    private static func prepare(_ entries: [ProtectedRootEntry], homeDirectory: URL) -> [PreparedEntry] {
        entries.compactMap { entry in
            guard !entry.path.isEmpty else { return nil }
            if entry.path.contains("*") {
                let pattern = normalizedPath(entry.path, homeDirectory: homeDirectory, resolvesSymlinks: false)
                return PreparedEntry(
                    reason: entry.reason,
                    globPattern: pattern,
                    globComponents: pattern.pathComponentsForPolicy,
                    foldedGlobComponents: pattern.lowercased().pathComponentsForPolicy,
                    paths: [],
                    foldedPaths: []
                )
            }
            let paths = Set([
                normalizedPath(entry.path, homeDirectory: homeDirectory, resolvesSymlinks: true),
                normalizedPath(entry.path, homeDirectory: homeDirectory, resolvesSymlinks: false),
            ])
            return PreparedEntry(
                reason: entry.reason,
                globPattern: nil,
                globComponents: [],
                foldedGlobComponents: [],
                paths: paths,
                foldedPaths: Set(paths.map { $0.lowercased() })
            )
        }
    }

    private static func match(
        _ entry: PreparedEntry,
        candidates: Set<String>,
        foldedCandidates: Set<String>,
        candidateComponents: [[String]],
        foldedCandidateComponents: [[String]]
    ) -> EntryMatch {
        if let pattern = entry.globPattern {
            if candidateComponents.contains(where: { componentsMatch(entry.globComponents, $0) }) {
                return .authoredSpelling
            }
            if foldedCandidateComponents.contains(where: { componentsMatch(entry.foldedGlobComponents, $0) }) {
                return .caseFoldedOnly(ScreenedEntry(reason: entry.reason, isGlob: true, paths: [pattern]))
            }
        } else {
            if !candidates.isDisjoint(with: entry.paths) {
                return .authoredSpelling
            }
            if !foldedCandidates.isDisjoint(with: entry.foldedPaths) {
                return .caseFoldedOnly(ScreenedEntry(reason: entry.reason, isGlob: false, paths: entry.paths))
            }
        }
        return .none
    }

    /// Case-folded near-miss confirmation: default APFS is case-insensitive,
    /// so "~/library" names the real ~/Library on disk yet fails the exact
    /// comparison. Confirm identity by asking the filesystem for both sides'
    /// canonical on-disk spelling (`canonicalPathKey`) rather than trusting
    /// the fold — a genuinely distinct ~/library on a case-sensitive volume
    /// canonicalizes differently and never matches.
    private static func caseConfirmedReason(for screened: [ScreenedEntry], candidates: Set<String>) -> String? {
        guard !screened.isEmpty else { return nil }

        let canonicalCandidates = addingCanonicalSpellings(to: candidates)
        for entry in screened {
            if entry.isGlob {
                guard let pattern = entry.paths.first else { continue }
                let canonicalPattern = canonicalDiskCasePath(pattern) ?? pattern
                if canonicalCandidates.contains(where: { globMatches(canonicalPattern, path: $0) }) {
                    return entry.reason
                }
            } else {
                let canonicalProtected = addingCanonicalSpellings(to: entry.paths)
                if !canonicalCandidates.isDisjoint(with: canonicalProtected) {
                    return entry.reason
                }
            }
        }
        return nil
    }

    private static func addingCanonicalSpellings(to paths: Set<String>) -> Set<String> {
        var expanded = paths
        for path in paths {
            if let canonical = canonicalDiskCasePath(path) {
                expanded.insert(canonical)
            }
        }
        return expanded
    }

    /// The on-disk canonical spelling of `path` (real case, firmlinks and
    /// symlinks resolved), from the deepest existing ancestor; components that
    /// don't exist are kept verbatim. Effectively always non-nil since `/`
    /// itself canonicalizes; `nil` only if even the root query fails.
    ///
    /// This is the mechanism the case-fold confirmation depends on in both
    /// directions: on a case-insensitive volume a twisted spelling resolves
    /// to the real case so it matches; on a case-sensitive volume two
    /// genuinely distinct fold-colliding directories canonicalize apart so
    /// they don't. `internal` for direct test coverage of that guarantee.
    static func canonicalDiskCasePath(_ path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        var missing: [String] = []
        while true {
            if let canonical = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
                guard !missing.isEmpty else { return canonical }
                var rebuilt = URL(fileURLWithPath: canonical)
                for component in missing.reversed() {
                    rebuilt.appendPathComponent(component)
                }
                return rebuilt.path
            }
            guard url.path != "/" else { return nil }
            missing.append(url.lastPathComponent)
            url = url.deletingLastPathComponent()
        }
    }

    static func normalizedPath(
        _ rawPath: String,
        homeDirectory: URL,
        resolvesSymlinks: Bool
    ) -> String {
        let expanded = expandTokens(rawPath, homeDirectory: homeDirectory)
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let path = resolvesSymlinks ? url.resolvingSymlinksInPath().path : url.path
        guard path.count > 1 else { return "/" }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Component-count-anchored glob match; `normalizedPattern` must already
    /// be normalized (tokens expanded, standardized).
    private static func globMatches(_ normalizedPattern: String, path: String) -> Bool {
        componentsMatch(normalizedPattern.pathComponentsForPolicy, path.pathComponentsForPolicy)
    }

    private static func componentsMatch(_ patternComponents: [String], _ pathComponents: [String]) -> Bool {
        guard patternComponents.count == pathComponents.count else { return false }

        return zip(patternComponents, pathComponents).allSatisfy { patternComponent, pathComponent in
            PathExpander.fnmatch(pattern: patternComponent, name: pathComponent)
        }
    }

    private static func expandTokens(_ rawPath: String, homeDirectory: URL) -> String {
        let home = homeDirectory.standardizedFileURL.path
        if rawPath == "~" { return home }
        if rawPath.hasPrefix("~/") {
            return home + String(rawPath.dropFirst())
        }
        return rawPath.replacingOccurrences(of: "${HOME}", with: home)
    }
}

private extension String {
    var pathComponentsForPolicy: [String] {
        URL(fileURLWithPath: self).pathComponents.filter { $0 != "/" }
    }
}
