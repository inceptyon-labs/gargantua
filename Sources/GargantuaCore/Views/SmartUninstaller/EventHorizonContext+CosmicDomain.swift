import Foundation

/// A live status line derived from the path Gargantua is currently inspecting.
///
/// The cosmic phrase is the brand voice; the display root is the literal
/// directory it represents. Pairing the two means every metaphor is anchored
/// to a real domain on disk — "Scanning container boundary topology" maps to
/// `~/Library/Containers`, not abstract space.
public struct CosmicDomain: Equatable, Sendable {
    public let displayRoot: String
    public let phrase: String
}

extension EventHorizonContext {
    /// Map a filesystem path to a cosmic-themed status line and a display root.
    /// Returns `nil` when no domain matches; callers fall back to the static
    /// `subtitle` from the per-tool context factory.
    ///
    /// Order matters: more specific roots come first so `~/Library/Developer/Xcode/DerivedData`
    /// wins over the bare `~/Library` fallback chain.
    public static func cosmicDomain(forPath path: String) -> CosmicDomain? {
        let normalized = abbreviateHome(path)
        for mapping in domainMappings {
            if normalized.hasPrefix(mapping.prefix) {
                return CosmicDomain(displayRoot: mapping.root, phrase: mapping.phrase)
            }
        }
        return nil
    }

    private static let domainMappings: [(prefix: String, root: String, phrase: String)] = [
        // Developer roots — most specific first so they don't get caught by ~/Library/Developer.
        ("~/Library/Developer/Xcode/DerivedData", "DerivedData", "Decoding derived data singularity"),
        ("~/Library/Developer/Xcode/iOS DeviceSupport", "iOS DeviceSupport", "Mapping simulator artifact constellations"),
        ("~/Library/Developer/Xcode/Archives", "Xcode Archives", "Cataloguing archived build remnants"),
        ("~/Library/Developer/CoreSimulator", "CoreSimulator", "Charting simulator orbit decay"),
        ("~/Library/Developer/Xcode", "Xcode", "Probing Xcode strata"),
        ("~/Library/Developer", "Developer", "Sweeping developer support fields"),

        // User Library — the bulk of cleanup work.
        ("~/Library/Caches", "~/Library/Caches", "Surveying cache residue in deep orbit"),
        ("~/Library/Logs", "~/Library/Logs", "Probing log telemetry streams"),
        ("~/Library/Containers", "~/Library/Containers", "Scanning container boundary topology"),
        ("~/Library/Group Containers", "Group Containers", "Mapping shared container fields"),
        ("~/Library/Application Support", "Application Support", "Cataloguing support constellation"),
        ("~/Library/Application Scripts", "Application Scripts", "Tracing sandbox script anchors"),
        ("~/Library/Preferences", "~/Library/Preferences", "Probing preference manifold geometry"),
        ("~/Library/Saved Application State", "Saved State", "Recovering quantum state from prior orbits"),
        ("~/Library/HTTPStorages", "HTTPStorages", "Sweeping network storage residue"),
        ("~/Library/WebKit", "WebKit", "Charting browser engine debris"),
        ("~/Library/LaunchAgents", "LaunchAgents", "Auditing autonomous agent signatures"),
        ("~/Library/Mobile Documents", "iCloud Drive", "Charting cloud-mirrored mass"),

        // Trash + downloads.
        ("~/.Trash", "~/.Trash", "Sweeping the disposal corridor"),
        ("~/Downloads", "~/Downloads", "Surveying recent arrival debris"),

        // Package managers.
        ("~/.npm", "~/.npm", "Detecting JS dependency debris"),
        ("~/.yarn", "~/.yarn", "Tracing Yarn lock anomalies"),
        ("~/.pnpm-store", "~/.pnpm-store", "Mapping pnpm content store"),
        ("~/.cargo", "~/.cargo", "Charting Cargo registry orbit"),
        ("~/.cache", "~/.cache", "Probing XDG cache residue"),
        ("~/.gradle", "~/.gradle", "Detecting Gradle wrapper remnants"),

        // Homebrew + system temp.
        ("/opt/homebrew/var/homebrew", "Homebrew cellar", "Auditing Homebrew formulae remnants"),
        ("/usr/local/var/homebrew", "Homebrew cellar", "Auditing Homebrew formulae remnants"),
        ("/private/var/folders", "system temp", "Scanning system temp accretion"),

        // System Library (read-mostly but valid for Light/Light scans).
        ("/Library/Caches", "/Library/Caches", "Probing root-level cache residue"),
        ("/Library/Logs", "/Library/Logs", "Tracing system log telemetry"),
        ("/Library/Application Support", "/Library/Application Support", "Mapping system support constellation"),

        // Catch-all home.
        ("~/Library", "~/Library", "Sweeping the user library nebula"),
    ]

    private static func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
