import Foundation

/// Auto-derived path-prefix cluster surfaced as a quick filter chip in the
/// File Health tab strip. Computed deterministically from the findings in a
/// single tab — no AI involved.
public struct FileHealthPathCluster: Identifiable, Equatable, Sendable {
    /// Full prefix string used for substring matching against `result.path`.
    public let id: String
    /// Compact label rendered on the chip (last 1-2 path components).
    public let displayLabel: String
    /// Number of findings in this tab whose path begins with `id`.
    public let count: Int
    /// Total size of the matching findings.
    public let totalSize: Int64

    public init(id: String, displayLabel: String, count: Int, totalSize: Int64) {
        self.id = id
        self.displayLabel = displayLabel
        self.count = count
        self.totalSize = totalSize
    }
}

/// Builds path-prefix clusters from a flat list of findings.
///
/// Heuristic: take the first three path components after `~` (or after the
/// scan root, when paths sit outside `~`), aggregate counts and bytes per
/// prefix, return the top N by count. The display label uses the last two
/// components so the chip stays compact (`dreamheist/builds`) while the
/// underlying id is the full prefix the user would type into the filter.
public enum FileHealthPathClusterer {

    /// Default depth — three components is the sweet spot between "everything
    /// in Development" (too coarse) and "every individual session dir"
    /// (too granular). Three keeps clusters at the project + first-subdir
    /// level for typical dev trees.
    public static let defaultDepth = 3

    /// Default chip cap — five chips fit comfortably on a single row beside
    /// the filter field without forcing a wrap on standard window widths.
    public static let defaultLimit = 5

    /// Minimum count for a cluster to surface as a chip. Singletons aren't
    /// useful as bulk-selection shortcuts.
    public static let minimumCount = 2

    /// Default sample-paths cap when building cluster summaries for the AI
    /// engine. Five paths is enough for the model to identify the
    /// directory's purpose without bloating the prompt.
    public static let defaultSampleSize = 5

    /// For each cluster, gather up to `limit` finding paths that fall under
    /// it. Used to build the AI prompt — the model sees a representative
    /// slice rather than the full list.
    public static func samplesByCluster(
        _ clusters: [FileHealthPathCluster],
        findings: [ScanResult],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        limit: Int = defaultSampleSize
    ) -> [String: [String]] {
        guard !clusters.isEmpty, !findings.isEmpty, limit > 0 else { return [:] }

        let expanded = expandedPrefixes(for: clusters, homeDirectory: homeDirectory)
        var samples: [String: [String]] = [:]
        for finding in findings {
            for cluster in clusters {
                guard let prefix = expanded[cluster.id],
                      finding.path.hasPrefix(prefix)
                else { continue }
                if (samples[cluster.id]?.count ?? 0) < limit {
                    samples[cluster.id, default: []].append(finding.path)
                }
                break
            }
        }
        return samples
    }

    /// Expand each cluster id back to an absolute prefix that matches the
    /// raw `ScanResult.path` strings (i.e., `~/X/` → `/Users/jason/X/`).
    static func expandedPrefixes(
        for clusters: [FileHealthPathCluster],
        homeDirectory: URL
    ) -> [String: String] {
        let homePath = homeDirectory.path.hasSuffix("/")
            ? homeDirectory.path
            : homeDirectory.path + "/"
        var out: [String: String] = [:]
        for cluster in clusters {
            if cluster.id.hasPrefix("~/") {
                out[cluster.id] = homePath + cluster.id.dropFirst(2)
            } else {
                out[cluster.id] = cluster.id
            }
        }
        return out
    }

    public static func clusters(
        from findings: [ScanResult],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        depth: Int = defaultDepth,
        limit: Int = defaultLimit
    ) -> [FileHealthPathCluster] {
        guard !findings.isEmpty, depth > 0, limit > 0 else { return [] }

        let homePrefix = homeDirectory.path.hasSuffix("/")
            ? homeDirectory.path
            : homeDirectory.path + "/"

        struct Bucket {
            var count: Int = 0
            var totalSize: Int64 = 0
        }
        var buckets: [String: Bucket] = [:]
        var firstSeen: [String: Int] = [:]
        var ordinal = 0

        for finding in findings {
            guard let prefix = clusterPrefix(
                forPath: finding.path,
                homePrefix: homePrefix,
                depth: depth
            ) else { continue }

            if firstSeen[prefix] == nil {
                firstSeen[prefix] = ordinal
                ordinal += 1
            }
            var bucket = buckets[prefix, default: Bucket()]
            bucket.count += 1
            let (next, overflow) = bucket.totalSize.addingReportingOverflow(finding.size)
            bucket.totalSize = overflow ? Int64.max : next
            buckets[prefix] = bucket
        }

        return buckets
            .filter { $0.value.count >= minimumCount }
            .sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count {
                    return lhs.value.count > rhs.value.count
                }
                // Stable tie-break by first-seen order so chip ordering
                // doesn't shimmer between scans of the same data.
                return (firstSeen[lhs.key] ?? .max) < (firstSeen[rhs.key] ?? .max)
            }
            .prefix(limit)
            .map { entry in
                FileHealthPathCluster(
                    id: entry.key,
                    displayLabel: displayLabel(for: entry.key),
                    count: entry.value.count,
                    totalSize: entry.value.totalSize
                )
            }
    }

    /// Extract the cluster key for `path`. Strips a trailing slash and stops
    /// at `depth` components below the home prefix (or at the absolute path's
    /// first `depth` components when `path` sits outside home).
    static func clusterPrefix(
        forPath path: String,
        homePrefix: String,
        depth: Int
    ) -> String? {
        let stripped: String
        let displayBase: String
        if path.hasPrefix(homePrefix) {
            stripped = String(path.dropFirst(homePrefix.count))
            displayBase = "~/"
        } else if path.hasPrefix("/") {
            stripped = String(path.dropFirst())
            displayBase = "/"
        } else {
            return nil
        }

        let components = stripped.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return nil }

        let take = min(depth, components.count)
        // If we couldn't reach the requested depth, the file is too shallow
        // for a meaningful cluster — skip rather than create a chip that
        // duplicates the filter behavior of typing the whole path.
        guard take == depth || components.count <= depth else { return nil }

        return displayBase + components.prefix(take).joined(separator: "/") + "/"
    }

    /// Turn the full prefix into a compact chip label — last two components
    /// without the leading `~/` or `/`. Falls back to the full prefix when
    /// fewer than two components are available.
    static func displayLabel(for prefix: String) -> String {
        var trimmed = prefix
        if trimmed.hasPrefix("~/") {
            trimmed = String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix("/") {
            trimmed = String(trimmed.dropFirst())
        }
        if trimmed.hasSuffix("/") {
            trimmed = String(trimmed.dropLast())
        }
        let components = trimmed.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return trimmed }
        return components.suffix(2).joined(separator: "/")
    }
}
