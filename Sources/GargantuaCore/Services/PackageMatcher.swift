import Foundation

/// Matches a candidate `AppInfo` against a list of macOS package IDs to find
/// receipts plausibly owned by the app.
///
/// Receipts are evidence, not permission — a match here only authorizes the
/// caller to *expand* the BOM and pipe candidates through the normal safety
/// classifier. Match heuristics, in priority order:
///
/// 1. **Exact bundle ID**: receipt ID equals the app's `bundleID`.
/// 2. **Bundle prefix**: receipt ID is the bundle ID followed by a dot
///    (e.g., `com.docker.docker` matches `com.docker.docker.helper`).
/// 3. **Reverse-DNS prefix**: receipt ID shares the bundle's first two
///    components (e.g., `com.docker.*` for `com.docker.docker`). Only
///    applied when the prefix is at least two components long, to keep
///    `com.*` from matching everything.
/// 4. **App-name slug**: receipt ID contains a sanitized app-name slug
///    derived from `AppInfo.name` (lowercase, hyphenated). Tightened to
///    avoid matching slugs of trivial length (≤2 chars) which would
///    over-match, e.g. naming an app `Go` should not pull in
///    `com.golang.tools`.
///
/// System packages are filtered out before any matching happens — `com.apple.*`
/// and `com.macports.*` will never reach the heuristic. Callers are still
/// expected to run downstream candidates through `protected_roots.yaml`,
/// but the system filter exists so we never even *propose* expanding an
/// Apple receipt against a third-party app.
public struct PackageMatcher: Sendable {
    /// Reverse-DNS prefixes that are never matched as candidates, regardless
    /// of how the heuristic stacks up. These are the receipts we never expand.
    public static let blockedSystemPrefixes: [String] = [
        "com.apple.",
        "com.macports.",
    ]

    public init() {}

    /// Whether `pkgID` is a system or platform-managed package that must
    /// never be matched against an app, even if the app's bundle ID happens
    /// to overlap.
    public func isSystemPackage(_ pkgID: String) -> Bool {
        let lower = pkgID.lowercased()
        return Self.blockedSystemPrefixes.contains(where: lower.hasPrefix)
    }

    /// Filter `packageIDs` down to those matching `app`. Order is preserved
    /// from the input list so callers can rely on a stable iteration order
    /// for tests and audit output.
    public func matches(packageIDs: [String], for app: AppInfo) -> [String] {
        let bundleID = app.bundleID.lowercased()
        let bundlePrefix = bundleID + "."
        let revDNSPrefix = reverseDNSPrefix(of: bundleID)
        let nameSlugs = nameSlugs(for: app)

        return packageIDs.filter { rawID in
            let candidate = rawID.lowercased()
            guard !isSystemPackage(candidate) else { return false }

            if candidate == bundleID { return true }
            if candidate.hasPrefix(bundlePrefix) { return true }
            if let revDNSPrefix, candidate.hasPrefix(revDNSPrefix) { return true }

            for slug in nameSlugs where containsSlug(candidate, slug: slug) {
                return true
            }
            return false
        }
    }

    // MARK: - Internal

    /// Two-component reverse-DNS prefix (`com.docker.`) used to widen the
    /// match. Returns `nil` when the bundle ID has fewer than two
    /// components, which avoids the degenerate `com.*` case.
    private func reverseDNSPrefix(of bundleID: String) -> String? {
        let parts = bundleID.split(separator: ".", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return parts.prefix(2).joined(separator: ".") + "."
    }

    /// Sanitized name slugs for matching against a package ID. Filters out
    /// short, ambiguous slugs (≤2 chars) and the team identifier path so
    /// match noise stays low.
    private func nameSlugs(for app: AppInfo) -> [String] {
        var raw: [String] = [app.name]
        if let displayName = app.displayName, displayName != app.name {
            raw.append(displayName)
        }

        var seen: Set<String> = []
        var slugs: [String] = []
        for candidate in raw {
            let lower = candidate.lowercased()
            let alphanumeric = lower.unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map(Character.init)
            let slug = String(alphanumeric)
            guard slug.count > 2, seen.insert(slug).inserted else { continue }
            slugs.append(slug)
        }
        return slugs
    }

    /// Whether `pkgID` contains `slug` as a discrete component (delimited by
    /// `.`, `-`, `_`, start, or end). Substring containment is too lax —
    /// a package ID `com.foo.barista` should not match an app `Bar`.
    private func containsSlug(_ pkgID: String, slug: String) -> Bool {
        let delimiters: Set<Character> = [".", "-", "_"]
        var index = pkgID.startIndex

        while let range = pkgID.range(of: slug, range: index ..< pkgID.endIndex) {
            let prevChar: Character? = range.lowerBound == pkgID.startIndex
                ? nil
                : pkgID[pkgID.index(before: range.lowerBound)]
            let nextChar: Character? = range.upperBound == pkgID.endIndex
                ? nil
                : pkgID[range.upperBound]

            let prevOK = prevChar.map { delimiters.contains($0) } ?? true
            let nextOK = nextChar.map { delimiters.contains($0) } ?? true
            if prevOK && nextOK {
                return true
            }
            index = pkgID.index(after: range.lowerBound)
        }
        return false
    }
}
