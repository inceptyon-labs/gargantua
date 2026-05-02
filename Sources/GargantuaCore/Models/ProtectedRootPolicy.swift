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

    public init(entries: [ProtectedRootEntry], failClosedReason: String? = nil) {
        self.entries = entries
        self.failClosedReason = failClosedReason
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

        let target = Self.normalizedPath(url.path, homeDirectory: homeDirectory, resolvesSymlinks: true)
        let alternateTarget = Self.normalizedPath(url.path, homeDirectory: homeDirectory, resolvesSymlinks: false)
        let candidatePaths = Set([target, alternateTarget])

        for entry in entries {
            guard !entry.path.isEmpty else { continue }
            if entry.path.contains("*") {
                if candidatePaths.contains(where: { Self.matchesGlob(entry.path, path: $0, homeDirectory: homeDirectory) }) {
                    return entry.reason
                }
            } else {
                let protectedPath = Self.normalizedPath(
                    entry.path,
                    homeDirectory: homeDirectory,
                    resolvesSymlinks: true
                )
                let alternateProtectedPath = Self.normalizedPath(
                    entry.path,
                    homeDirectory: homeDirectory,
                    resolvesSymlinks: false
                )
                if candidatePaths.contains(protectedPath) || candidatePaths.contains(alternateProtectedPath) {
                    return entry.reason
                }
            }
        }

        return nil
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

    private static func matchesGlob(_ pattern: String, path: String, homeDirectory: URL) -> Bool {
        let normalizedPattern = normalizedPath(pattern, homeDirectory: homeDirectory, resolvesSymlinks: false)
        let patternComponents = normalizedPattern.pathComponentsForPolicy
        let pathComponents = path.pathComponentsForPolicy
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
