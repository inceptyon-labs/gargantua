import Foundation

public extension RemnantScanner {
    /// Expand one template without touching the filesystem.
    static func expand(template: String, for app: AppInfo) -> String? {
        expandAll(template: template, for: app).first
    }

    /// Expand one template into every safe app-name variant it requests.
    ///
    /// `{appNameVariant}` fans out to a bounded, sanitized set containing the
    /// original app name plus no-space, hyphen, underscore, lowercase,
    /// base-channel, and bundle-derived variants.
    static func expandAll(template: String, for app: AppInfo) -> [String] {
        guard !template.contains("{teamID}") || app.teamIdentifier?.isEmpty == false else {
            return []
        }

        let replacements: [(token: String, values: [String])] = [
            ("{bundleID}", [app.bundleID]),
            ("{bundleName}", bundleDerivedVariants(for: app)),
            ("{appName}", [app.name]),
            ("{appNameNoSpace}", [removeSpaces(app.name)]),
            ("{appNameHyphen}", [joinWords(app.name, separator: "-")]),
            ("{appNameUnderscore}", [joinWords(app.name, separator: "_")]),
            ("{appNameLowercase}", [app.name.lowercased()]),
            ("{appNameBase}", [baseChannelName(app.name)]),
            ("{appNameVariant}", appNameVariants(for: app)),
            ("{teamID}", [app.teamIdentifier ?? ""]),
        ]

        let expanded = replacements.reduce([template]) { current, replacement in
            guard current.contains(where: { $0.contains(replacement.token) }) else {
                return current
            }
            // Sanitize every substituted value, not just `{appNameVariant}`.
            // `{appName}`, `{bundleID}`, `{bundleName}`, and `{teamID}` come
            // straight from a bundle's Info.plist, which an attacker controls.
            // Without this, a value like "../../.ssh" expands a template such
            // as "~/Library/Caches/{appName}" into a path that escapes the
            // intended cleanup root and deletes unrelated user data.
            let safeValues = replacement.values.compactMap(safeVariant)
            guard !safeValues.isEmpty else { return [] }
            return current.flatMap { candidate in
                safeValues.map {
                    candidate.replacingOccurrences(of: replacement.token, with: $0)
                }
            }
        }

        // Defense in depth: never emit a candidate that still contains a `..`
        // component after tilde expansion, even if a future template or token
        // slips one past the per-value filter above.
        return unique(expanded.map { ($0 as NSString).expandingTildeInPath })
            .filter { !pathContainsParentTraversal($0) }
    }

    /// Safe app-name variants for broad Mole-style remnant path expansion.
    static func appNameVariants(for app: AppInfo) -> [String] {
        var candidates: [String] = [app.name]
        if let displayName = app.displayName, displayName != app.name {
            candidates.append(displayName)
        }
        candidates.append(contentsOf: candidates.map(baseChannelName))
        candidates.append(contentsOf: bundleDerivedVariants(for: app))

        var variants: [String] = []
        for candidate in candidates {
            let lowercase = candidate.lowercased()
            variants.append(candidate)
            variants.append(removeSpaces(candidate))
            variants.append(joinWords(candidate, separator: "-"))
            variants.append(joinWords(candidate, separator: "_"))
            variants.append(lowercase)
            variants.append(removeSpaces(lowercase))
            variants.append(joinWords(lowercase, separator: "-"))
            variants.append(joinWords(lowercase, separator: "_"))
        }

        return unique(variants.compactMap(safeVariant))
    }
}

extension RemnantScanner {
    private static func bundleDerivedVariants(for app: AppInfo) -> [String] {
        let parts = app.bundleID
            .split(separator: ".")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let last = parts.last else { return [] }
        return unique([last, last.lowercased()])
    }

    private static func baseChannelName(_ name: String) -> String {
        let suffixes = [
            "Alpha", "Beta", "Canary", "Dev", "Developer", "Nightly",
            "Preview", "Release", "Stable", "Insider", "Insiders",
        ]
        let escaped = suffixes.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = #"(?i)(?:[\s._-]+)(\#(escaped))$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return name }
        let range = NSRange(name.startIndex ..< name.endIndex, in: name)
        return regex.stringByReplacingMatches(in: name, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeSpaces(_ name: String) -> String {
        name.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private static func joinWords(_ name: String, separator: String) -> String {
        name.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    /// True when a fully-expanded path still contains a `..` component that
    /// could walk outside the template's intended root.
    private static func pathContainsParentTraversal(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: true).contains("..")
    }

    private static func safeVariant(_ variant: String) -> String? {
        let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\0") else {
            return nil
        }
        return trimmed
    }

    static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
