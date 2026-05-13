import Foundation

// MARK: - Classification

/// What a duplicate group "is" in plain English. Built deterministically from
/// path patterns — no AI, no I/O.
public struct DuplicateGroupClassification: Sendable, Equatable {
    /// Human-readable group title (e.g. "Adobe Premiere Pro · Mask autosaves").
    public let title: String
    /// SF Symbol name representing the category.
    public let icon: String
    /// Coarse category bucket — drives icon choice and tint hints.
    public let category: Category
    /// One-line explainer for the user (e.g. "Premiere autosaves the same mask
    /// data each session — typically you keep the newest and trash the rest.").
    public let explainer: String
    /// Tilde-collapsed common parent path of the group, useful as a breadcrumb
    /// under the title. May be empty if paths share no meaningful prefix.
    public let pathCrumb: String

    public enum Category: String, Sendable, Equatable {
        case appCache
        case appAutosave
        case appSupport
        case devArtifact
        case media
        case userDocument
        case download
        case generic
    }
}

// MARK: - Classifier

public enum DuplicateGroupClassifier {
    /// Classify a duplicate group from its paths.
    public static func classify(_ group: DuplicateGroup) -> DuplicateGroupClassification {
        classify(paths: group.files.map(\.path))
    }

    public static func classify(paths: [String]) -> DuplicateGroupClassification {
        guard !paths.isEmpty else {
            return DuplicateGroupClassification(
                title: "Duplicate files",
                icon: "doc.on.doc.fill",
                category: .generic,
                explainer: "Identical file content. Keep one copy and review the rest before removing.",
                pathCrumb: ""
            )
        }

        let commonPrefixComponents = longestCommonPrefixComponents(paths: paths)
        let commonPath = "/" + commonPrefixComponents.joined(separator: "/")
        let crumb = tildeCollapsed(commonPath)

        // Match patterns in priority order — the most specific first.
        for pattern in patterns where pattern.matches(commonPrefixComponents, paths[0]) {
            return pattern.build(commonPrefixComponents, paths[0], crumb)
        }

        // Generic fallback. Try to pull a useful name from the deepest common
        // folder; otherwise fall back to a neutral title.
        let title = commonPrefixComponents.last.map { humanize($0) } ?? "Duplicate files"
        return DuplicateGroupClassification(
            title: title,
            icon: "doc.on.doc.fill",
            category: .generic,
            explainer: "Identical file content. Keep one copy and review the rest before removing.",
            pathCrumb: crumb
        )
    }
}

// MARK: - Patterns

private struct PathPattern {
    let matches: ([String], String) -> Bool
    let build: ([String], String, String) -> DuplicateGroupClassification
}

private let patterns: [PathPattern] = [
    // Adobe Premiere autosaves (Mask files, project autosaves, etc.)
    PathPattern(
        matches: { components, _ in
            joined(components).contains("Adobe")
                && (joined(components).contains("Auto-Save") || joined(components).lowercased().contains("autosave"))
        },
        build: { _, sample, crumb in
            let isMasks = sample.contains("Masks") || sample.lowercased().hasSuffix(".prmf")
            return DuplicateGroupClassification(
                title: isMasks
                    ? "Adobe Premiere Pro · Mask autosaves"
                    : "Adobe Premiere Pro · Autosaves",
                icon: "clock.arrow.circlepath",
                category: .appAutosave,
                explainer: isMasks
                    ? "Premiere writes the same mask data every autosave session. Typically safe to keep the newest and trash the rest."
                    : "Premiere keeps a chain of autosave snapshots. Safe to thin out older ones — the live project file is unaffected.",
                pathCrumb: crumb
            )
        }
    ),

    // Adobe Media Cache
    PathPattern(
        matches: { components, _ in
            let j = joined(components)
            return j.contains("Adobe") && (j.contains("Media Cache") || j.contains("Common"))
        },
        build: { _, _, crumb in
            DuplicateGroupClassification(
                title: "Adobe · Media Cache",
                icon: "internaldrive",
                category: .appCache,
                explainer: "Adobe apps cache decoded media frames here. Regenerated automatically when you reopen a project.",
                pathCrumb: crumb
            )
        }
    ),

    // node_modules — directory-marker pattern; each duplicate is a vendored package file.
    PathPattern(
        matches: { _, sample in sample.contains("/node_modules/") },
        build: { _, sample, crumb in
            // Try to surface the package name (the directory after node_modules)
            let pkg = packageNameAfter(marker: "/node_modules/", in: sample)
            let title = pkg.map { "node_modules · \($0)" } ?? "node_modules · Vendored packages"
            return DuplicateGroupClassification(
                title: title,
                icon: "shippingbox",
                category: .devArtifact,
                explainer: "Same package vendored into multiple projects. Reinstallable with `npm install` / `pnpm install`.",
                pathCrumb: crumb
            )
        }
    ),

    // Xcode DerivedData
    PathPattern(
        matches: { _, sample in sample.contains("/Library/Developer/Xcode/DerivedData/") },
        build: { _, _, crumb in
            DuplicateGroupClassification(
                title: "Xcode · Derived Data",
                icon: "hammer",
                category: .devArtifact,
                explainer: "Xcode build outputs and indexes. Rebuilds on next compile.",
                pathCrumb: crumb
            )
        }
    ),

    // CoreSimulator
    PathPattern(
        matches: { _, sample in sample.contains("/Library/Developer/CoreSimulator/") },
        build: { _, _, crumb in
            DuplicateGroupClassification(
                title: "iOS Simulator · Caches",
                icon: "iphone",
                category: .devArtifact,
                explainer: "Simulator runtimes and per-device caches. Regenerated when you boot a simulator.",
                pathCrumb: crumb
            )
        }
    ),

    // ~/Library/Caches/<bundleID>/...
    PathPattern(
        matches: { _, sample in sample.range(of: "/Library/Caches/") != nil },
        build: { _, sample, crumb in
            let bundleID = bundleIDAfter(marker: "/Library/Caches/", in: sample)
            let app = bundleID.map { humanizedAppName(fromBundleID: $0) }
            return DuplicateGroupClassification(
                title: app.map { "\($0) · Cache" } ?? "App Cache",
                icon: "internaldrive",
                category: .appCache,
                explainer: "Cached data the app rebuilds on demand. Safe to clear; the app may take a moment to repopulate it.",
                pathCrumb: crumb
            )
        }
    ),

    // ~/Library/Application Support/<bundleID>/...
    PathPattern(
        matches: { _, sample in sample.contains("/Library/Application Support/") },
        build: { _, sample, crumb in
            let bundleID = bundleIDAfter(marker: "/Library/Application Support/", in: sample)
            let app = bundleID.map { humanizedAppName(fromBundleID: $0) }
            return DuplicateGroupClassification(
                title: app.map { "\($0) · App Support" } ?? "App Support",
                icon: "gearshape",
                category: .appSupport,
                explainer: "App-managed support files. Some apps store user data here — review before removing.",
                pathCrumb: crumb
            )
        }
    ),

    // ~/Library/Containers/<bundleID>/Data/...
    PathPattern(
        matches: { _, sample in sample.contains("/Library/Containers/") },
        build: { _, sample, crumb in
            let bundleID = bundleIDAfter(marker: "/Library/Containers/", in: sample)
            let app = bundleID.map { humanizedAppName(fromBundleID: $0) }
            return DuplicateGroupClassification(
                title: app.map { "\($0) · Sandbox container" } ?? "Sandbox container",
                icon: "shield",
                category: .appSupport,
                explainer: "Sandboxed app's private data. Often contains user content — review carefully before removing.",
                pathCrumb: crumb
            )
        }
    ),

    // ~/Downloads
    PathPattern(
        matches: { _, sample in sample.contains("/Downloads/") },
        build: { _, _, crumb in
            DuplicateGroupClassification(
                title: "Downloads",
                icon: "arrow.down.circle",
                category: .download,
                explainer: "Files saved from the web or AirDrop. Removing isn't recoverable from inside the app — make sure you don't need them first.",
                pathCrumb: crumb
            )
        }
    ),

    // ~/Movies, ~/Music, ~/Pictures
    PathPattern(
        matches: { _, sample in
            sample.contains("/Movies/") || sample.contains("/Music/") || sample.contains("/Pictures/")
        },
        build: { _, sample, crumb in
            let bucket: String
            let icon: String
            if sample.contains("/Movies/") {
                bucket = "Movies"
                icon = "film"
            } else if sample.contains("/Music/") {
                bucket = "Music"
                icon = "music.note"
            } else {
                bucket = "Pictures"
                icon = "photo.stack"
            }
            return DuplicateGroupClassification(
                title: "\(bucket) · Personal media",
                icon: icon,
                category: .media,
                explainer: "Personal media files. Confirm you have a backup before removing — these are usually irreplaceable.",
                pathCrumb: crumb
            )
        }
    ),

    // ~/Documents, ~/Desktop
    PathPattern(
        matches: { _, sample in
            sample.contains("/Documents/") || sample.contains("/Desktop/")
        },
        build: { _, sample, crumb in
            let bucket = sample.contains("/Desktop/") ? "Desktop" : "Documents"
            return DuplicateGroupClassification(
                title: "\(bucket) · User files",
                icon: "doc.text",
                category: .userDocument,
                explainer: "User-authored files. Review carefully — losing the wrong copy may be irreversible.",
                pathCrumb: crumb
            )
        }
    ),
]

// MARK: - Helpers

func pathComponents(_ path: String) -> [String] {
    // Strip leading slash so the empty leading component doesn't perturb the
    // common-prefix length count.
    path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
}

private func longestCommonPrefixComponents(paths: [String]) -> [String] {
    let split = paths.map(pathComponents)
    let len = longestCommonPrefixLength(of: split)
    return Array(split[0].prefix(len))
}

func longestCommonPrefixLength(of arrays: [[String]]) -> Int {
    guard let first = arrays.first else { return 0 }
    var len = first.count
    for other in arrays.dropFirst() {
        len = min(len, other.count)
        var i = 0
        while i < len, first[i] == other[i] { i += 1 }
        len = i
        if len == 0 { return 0 }
    }
    return len
}

private func tildeCollapsed(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") {
        return "~" + path.dropFirst(home.count)
    }
    // Fallback for sandbox paths or other-user paths: strip /Users/<name>/
    let nsPath = path as NSString
    let parts = nsPath.pathComponents
    if parts.count >= 3, parts[1] == "Users" {
        let rest = parts.dropFirst(3).joined(separator: "/")
        return rest.isEmpty ? "~" : "~/" + rest
    }
    return path
}

private func joined(_ components: [String]) -> String {
    "/" + components.joined(separator: "/")
}

/// Extract the path component immediately after `marker` in `path`, if any.
/// Used to pull bundle IDs out of `~/Library/Caches/<bundleID>/...`.
private func bundleIDAfter(marker: String, in path: String) -> String? {
    guard let range = path.range(of: marker) else { return nil }
    let tail = path[range.upperBound...]
    return tail.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init)
}

private func packageNameAfter(marker: String, in path: String) -> String? {
    guard let range = path.range(of: marker) else { return nil }
    let tail = path[range.upperBound...]
    let first = tail.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init)
    // Scoped packages: "@scope/pkg" lives as ["@scope", "pkg"]. Re-join when present.
    guard let leading = first, leading.hasPrefix("@") else { return first }
    let parts = tail.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return leading }
    return "\(parts[0])/\(parts[1])"
}

/// Humanize a bundle ID like `com.apple.dt.Xcode` → "Xcode".
private func humanizedAppName(fromBundleID bundleID: String) -> String {
    if let known = knownAppName(forBundleID: bundleID) { return known }
    // Take the last meaningful segment.
    let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    return humanize(last)
}

/// Title-case + space-insert a component name like `Auto-Save` or `Premiere Pro`.
/// Conservative: leaves existing casing alone if the string already contains
/// letters of mixed case (it probably already reads fine).
private func humanize(_ raw: String) -> String {
    if raw.contains(" ") || raw.contains("-") { return raw }
    if raw.contains(where: { $0.isUppercase }) && raw.contains(where: { $0.isLowercase }) {
        return raw
    }
    return raw.prefix(1).uppercased() + raw.dropFirst()
}
