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
        for mapping in domainMappings where normalized.hasPrefix(mapping.prefix) {
            return CosmicDomain(displayRoot: mapping.root, phrase: mapping.phrase)
        }
        return nil
    }

    private struct DomainMapping {
        let prefix: String
        let root: String
        let phrase: String
    }

    private static let domainMappings: [DomainMapping] = [
        // Developer roots — most specific first so they don't get caught by ~/Library/Developer.
        DomainMapping(prefix: "~/Library/Developer/Xcode/DerivedData", root: "DerivedData", phrase: "Decoding derived data singularity"),
        DomainMapping(prefix: "~/Library/Developer/Xcode/iOS DeviceSupport", root: "iOS DeviceSupport", phrase: "Mapping simulator artifact constellations"),
        DomainMapping(prefix: "~/Library/Developer/Xcode/Archives", root: "Xcode Archives", phrase: "Cataloguing archived build remnants"),
        DomainMapping(prefix: "~/Library/Developer/CoreSimulator", root: "CoreSimulator", phrase: "Charting simulator orbit decay"),
        DomainMapping(prefix: "~/Library/Developer/Xcode", root: "Xcode", phrase: "Probing Xcode strata"),
        DomainMapping(prefix: "~/Library/Developer", root: "Developer", phrase: "Sweeping developer support fields"),

        // User Library — the bulk of cleanup work.
        DomainMapping(prefix: "~/Library/Caches", root: "~/Library/Caches", phrase: "Surveying cache residue in deep orbit"),
        DomainMapping(prefix: "~/Library/Logs", root: "~/Library/Logs", phrase: "Probing log telemetry streams"),
        DomainMapping(prefix: "~/Library/Containers", root: "~/Library/Containers", phrase: "Scanning container boundary topology"),
        DomainMapping(prefix: "~/Library/Group Containers", root: "Group Containers", phrase: "Mapping shared container fields"),
        DomainMapping(prefix: "~/Library/Application Support", root: "Application Support", phrase: "Cataloguing support constellation"),
        DomainMapping(prefix: "~/Library/Application Scripts", root: "Application Scripts", phrase: "Tracing sandbox script anchors"),
        DomainMapping(prefix: "~/Library/Preferences", root: "~/Library/Preferences", phrase: "Probing preference manifold geometry"),
        DomainMapping(prefix: "~/Library/Saved Application State", root: "Saved State", phrase: "Recovering quantum state from prior orbits"),
        DomainMapping(prefix: "~/Library/HTTPStorages", root: "HTTPStorages", phrase: "Sweeping network storage residue"),
        DomainMapping(prefix: "~/Library/WebKit", root: "WebKit", phrase: "Charting browser engine debris"),
        DomainMapping(prefix: "~/Library/LaunchAgents", root: "LaunchAgents", phrase: "Auditing autonomous agent signatures"),
        DomainMapping(prefix: "~/Library/Mobile Documents", root: "iCloud Drive", phrase: "Charting cloud-mirrored mass"),

        // Trash + downloads.
        DomainMapping(prefix: "~/.Trash", root: "~/.Trash", phrase: "Sweeping the disposal corridor"),
        DomainMapping(prefix: "~/Downloads", root: "~/Downloads", phrase: "Surveying recent arrival debris"),

        // Package managers.
        DomainMapping(prefix: "~/.npm", root: "~/.npm", phrase: "Detecting JS dependency debris"),
        DomainMapping(prefix: "~/.yarn", root: "~/.yarn", phrase: "Tracing Yarn lock anomalies"),
        DomainMapping(prefix: "~/.pnpm-store", root: "~/.pnpm-store", phrase: "Mapping pnpm content store"),
        DomainMapping(prefix: "~/.cargo", root: "~/.cargo", phrase: "Charting Cargo registry orbit"),
        DomainMapping(prefix: "~/.cache", root: "~/.cache", phrase: "Probing XDG cache residue"),
        DomainMapping(prefix: "~/.gradle", root: "~/.gradle", phrase: "Detecting Gradle wrapper remnants"),

        // Homebrew + system temp.
        DomainMapping(prefix: "/opt/homebrew/var/homebrew", root: "Homebrew cellar", phrase: "Auditing Homebrew formulae remnants"),
        DomainMapping(prefix: "/usr/local/var/homebrew", root: "Homebrew cellar", phrase: "Auditing Homebrew formulae remnants"),
        DomainMapping(prefix: "/private/var/folders", root: "system temp", phrase: "Scanning system temp accretion"),

        // System Library (read-mostly but valid for Light/Light scans).
        DomainMapping(prefix: "/Library/Caches", root: "/Library/Caches", phrase: "Probing root-level cache residue"),
        DomainMapping(prefix: "/Library/Logs", root: "/Library/Logs", phrase: "Tracing system log telemetry"),
        DomainMapping(prefix: "/Library/Application Support", root: "/Library/Application Support", phrase: "Mapping system support constellation"),

        // Catch-all home.
        DomainMapping(prefix: "~/Library", root: "~/Library", phrase: "Sweeping the user library nebula"),
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
