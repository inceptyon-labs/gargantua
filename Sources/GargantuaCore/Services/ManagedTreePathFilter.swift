import Foundation

/// Classifies a filesystem path as living inside a "managed tree" — a
/// dependency cache, build artifact directory, OS cache, or expanded bundle
/// where the user cannot safely delete an individual byte-identical duplicate
/// without breaking the surrounding container.
///
/// Duplicate Finder uses this to hide groups whose every member lives inside
/// a managed tree. Those duplicates are real (fclones hashes content, not
/// names) but acting on them at the file level is the wrong remedy — the user
/// should clear the whole tree via Deep Clean, or live with the redundancy.
public enum ManagedTreePathFilter {

    /// `true` when `path` lives inside a known dependency, build, cache,
    /// bundle, or system tree. The check is purely path-based; no filesystem
    /// IO. `homeDirectory` enables `$HOME`-relative checks (user Library,
    /// Trash); when omitted, only absolute and component-based rules apply.
    public static func isManaged(_ path: String, homeDirectory: URL? = nil) -> Bool {
        let lower = path.lowercased()

        // Absolute system trees: anything under /System, /Library, /private,
        // /usr, /var, /opt is OS or shared-app territory the user can't pick
        // at file-by-file. /Applications/ is included because .app/.framework
        // bundles inside it produce big duplicate fan-outs (resources,
        // localizations) that are intra-bundle and unactionable.
        for prefix in absoluteManagedPrefixes where lower.hasPrefix(prefix) {
            return true
        }

        // $HOME-relative: ~/Library/ houses Containers, Mail, Mobile
        // Documents (iCloud), Application Support, Group Containers — all
        // primary sources of byte-identical duplicates the user shouldn't
        // act on at the file level. ~/.Trash is items pending deletion.
        if let homeDirectory {
            let homePrefix = homeDirectory.path.hasSuffix("/")
                ? homeDirectory.path
                : homeDirectory.path + "/"
            for suffix in homeRelativeManagedSuffixes where path.hasPrefix(homePrefix + suffix) {
                return true
            }
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        for (index, component) in components.enumerated() {
            let lowerComponent = component.lowercased()
            if managedDirectoryNames.contains(lowerComponent) { return true }
            if hasManagedExtension(component) { return true }
            // Foundry / Forge convention: `lib/<package>/` is where forge
            // installs Solidity dependencies (openzeppelin-contracts,
            // forge-std, etc.). Match when the package name contains a
            // hyphen — generic enough to catch the dominant Forge deps,
            // narrow enough that a user's plain `lib/utils/` source dir
            // stays visible.
            if lowerComponent == "lib",
               index + 1 < components.count,
               components[index + 1].contains("-") {
                return true
            }
            if knownVendoredPackageNames.contains(lowerComponent) { return true }
        }

        for substring in managedSubstrings where lower.contains(substring) {
            return true
        }

        return false
    }

    private static func hasManagedExtension(_ component: Substring) -> Bool {
        guard let dotIndex = component.lastIndex(of: ".") else { return false }
        let ext = component[component.index(after: dotIndex)...].lowercased()
        return managedBundleExtensions.contains(ext)
    }

    /// Path component names (case-insensitive) that mark the entire subtree
    /// as managed. Conservative on purpose — only directory names whose
    /// presence in any path segment is a strong signal of dependency / build
    /// / VCS / cache content.
    private static let managedDirectoryNames: Set<String> = [
        "node_modules",
        "bower_components",
        ".git",
        ".svn",
        ".hg",
        "pods",
        "carthage",
        "vendor",
        ".cargo",
        ".gradle",
        "__pycache__",
        ".venv",
        ".tox",
        "deriveddata",
        ".next",
        ".nuxt",
        ".swiftpm",
        ".build",
        "index.noindex",
        ".terraform",
        ".pub-cache",
        ".dart_tool",
        ".bundle",
    ]

    /// Bundle file extensions whose interior is considered managed. Any path
    /// component ending in one of these (e.g. `Foo.app/Contents/...`) is
    /// inside a bundle the user shouldn't pick at file-by-file.
    private static let managedBundleExtensions: Set<String> = [
        "app",
        "framework",
        "kext",
        "xcarchive",
        "xcassets",
        "xcdatamodel",
        "xcdatamodeld",
        "lproj",
        "dsym",
        "appex",
        "systemextension",
        "docset",
        "imovielibrary",
        "fcpbundle",
        "photoslibrary",
        "musiclibrary",
        "tvlibrary",
        "pkg",
        "mpkg",
    ]

    /// Path substrings that mark managed regions independent of segment
    /// boundaries. Most user-Library subfolders are now caught by
    /// `homeRelativeManagedSuffixes`; this list stays for absolute paths
    /// that don't anchor under `$HOME`.
    private static let managedSubstrings: [String] = [
        "/library/caches/",
        "/library/developer/xcode/",
        "/library/developer/coresimulator/",
        "/library/logs/",
    ]

    /// Absolute path prefixes (lowercased) where any duplicate is by
    /// definition system or shared-app territory. Conservative on purpose —
    /// only roots whose contents the user should not pick at file-by-file.
    private static let absoluteManagedPrefixes: [String] = [
        "/system/",
        "/library/",
        "/private/",
        "/usr/",
        "/var/",
        "/opt/",
        "/applications/",
        "/cores/",
    ]

    /// Path suffixes (relative to `$HOME`) marked managed. The Library tree
    /// is the dominant duplicate source on a typical Mac — sandboxed app
    /// containers, Mail attachments, iCloud sync mirrors, and shared-app
    /// data all live under it and none are file-level actionable.
    ///
    /// The `Documents/<vendor>/` entries cover apps that drop their working
    /// directories inside Documents (Adobe Premiere auto-saves, Office swap
    /// files, etc.) — those duplicates look user-authored but the app
    /// regenerates them next launch, so file-by-file cleanup is futile.
    private static let homeRelativeManagedSuffixes: [String] = [
        "Library/",
        ".Trash/",
        "Documents/Adobe/",
        "Documents/Microsoft/",
        "Documents/Microsoft User Data/",
        "Documents/Affinity/",
        "Documents/Logic/",
        "Documents/Final Cut Pro/",
        "Documents/iMovie/",
        "Documents/GarageBand/",
        "Documents/Steam/",
    ]

    /// Common vendored-package directory names that don't contain a hyphen,
    /// so the generic `lib/<hyphen-name>` heuristic above misses them. Keep
    /// this list short and unambiguous — names that, as a path component,
    /// are almost certainly a vendored dependency rather than a user source
    /// directory.
    private static let knownVendoredPackageNames: Set<String> = [
        "solmate",
        "solady",
        "openzeppelin",
    ]
}
