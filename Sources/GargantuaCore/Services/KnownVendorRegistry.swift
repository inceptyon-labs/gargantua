import Foundation

/// A single entry mapping a Team Identifier (and optionally a bundle ID prefix)
/// to a display name and zero or more sensitive categories.
public struct KnownVendorEntry: Sendable, Equatable {
    /// Apple Team ID from the signing certificate (e.g. `EQHXZ8M8AV`).
    public let teamIdentifier: String

    /// Optional bundle-ID prefix to narrow the match. When non-nil the resolver
    /// must match both the team ID *and* the bundle ID prefix. Used for vendors
    /// that ship many products under one team ID but only some are sensitive
    /// (e.g. Apple ships both Time Machine helpers and System Information).
    public let bundleIDPrefix: String?

    /// Human-readable vendor or product name.
    public let displayName: String

    /// Categories this entry belongs to. Empty means "known, not sensitive."
    public let sensitiveCategories: Set<SensitiveVendorCategory>

    public init(
        teamIdentifier: String,
        bundleIDPrefix: String? = nil,
        displayName: String,
        sensitiveCategories: Set<SensitiveVendorCategory> = []
    ) {
        self.teamIdentifier = teamIdentifier
        self.bundleIDPrefix = bundleIDPrefix
        self.displayName = displayName
        self.sensitiveCategories = sensitiveCategories
    }
}

/// Curated lookup table for well-known third-party Team IDs.
///
/// Two responsibilities:
///   1. Distinguish "third-party-known" from "third-party-unknown" so the
///      Background Activity Review surface can default the former to safe.
///   2. Surface vendors whose privileges (network, input, MDM, keychain, etc.)
///      mean they should default to `review` *regardless* of signing status.
///
/// The registry is intentionally small and conservative — when in doubt,
/// classify as third-party-unknown rather than mis-marking a sensitive vendor
/// as safe. New entries should cite the source of the Team ID (App Store,
/// vendor docs, signed binary on a clean machine).
public struct KnownVendorRegistry: Sendable {
    public let entries: [KnownVendorEntry]

    public init(entries: [KnownVendorEntry]) {
        self.entries = entries
    }

    /// Best match for a binary signed by `teamIdentifier` with optional
    /// `bundleIdentifier`. Bundle-ID-qualified entries are preferred over
    /// team-only entries.
    public func lookup(teamIdentifier: String?, bundleIdentifier: String?) -> KnownVendorEntry? {
        guard let teamIdentifier else { return nil }

        var teamOnlyMatch: KnownVendorEntry?
        for entry in entries where entry.teamIdentifier == teamIdentifier {
            if let prefix = entry.bundleIDPrefix {
                if let bundleIdentifier, bundleIdentifier.hasPrefix(prefix) {
                    return entry
                }
            } else if teamOnlyMatch == nil {
                teamOnlyMatch = entry
            }
        }
        return teamOnlyMatch
    }

    /// Default registry shipped with Gargantua.
    ///
    /// Conservative starter set — covers vendors that commonly appear in
    /// `~/Library/LaunchAgents` and `/Library/LaunchDaemons` on developer
    /// machines, with a bias toward marking sensitive categories correctly.
    public static let `default` = KnownVendorRegistry(entries: [

        // MARK: - Password managers

        .init(teamIdentifier: "2BUA8C4S2C", displayName: "1Password",
              sensitiveCategories: [.passwordManager]),
        .init(teamIdentifier: "LBQJ97UU8K", displayName: "Bitwarden",
              sensitiveCategories: [.passwordManager]),
        .init(teamIdentifier: "N4F7D6BFT9", displayName: "Dashlane",
              sensitiveCategories: [.passwordManager]),

        // MARK: - VPN / networking

        .init(teamIdentifier: "2SUMHMRX6Y", displayName: "Tailscale",
              sensitiveCategories: [.vpn]),
        .init(teamIdentifier: "G69SCX94XU", bundleIDPrefix: "ch.protonvpn",
              displayName: "Proton VPN", sensitiveCategories: [.vpn]),
        .init(teamIdentifier: "5G27Y2ZPLV", displayName: "Mullvad VPN",
              sensitiveCategories: [.vpn]),
        .init(teamIdentifier: "2752YQ4BKE", displayName: "OpenVPN",
              sensitiveCategories: [.vpn]),

        // MARK: - Backup / sync

        .init(teamIdentifier: "G7HH3F8CAK", displayName: "Dropbox",
              sensitiveCategories: [.backup]),
        .init(teamIdentifier: "77F6UU56G7", displayName: "Backblaze",
              sensitiveCategories: [.backup]),
        .init(teamIdentifier: "L4576XJC4Y", displayName: "Carbon Copy Cloner",
              sensitiveCategories: [.backup]),

        // MARK: - Security / AV

        .init(teamIdentifier: "X9E956P446", displayName: "Malwarebytes",
              sensitiveCategories: [.security]),
        .init(teamIdentifier: "9PTGMPNXZ2", displayName: "CrowdStrike Falcon",
              sensitiveCategories: [.security]),
        .init(teamIdentifier: "4MAJ7FA837", displayName: "SentinelOne",
              sensitiveCategories: [.security]),

        // MARK: - MDM

        .init(teamIdentifier: "483DWKW443", displayName: "Jamf",
              sensitiveCategories: [.mdm]),
        .init(teamIdentifier: "P57TF77W5R", displayName: "Kandji",
              sensitiveCategories: [.mdm]),
        .init(teamIdentifier: "8XA8U5HCXR", displayName: "Mosyle",
              sensitiveCategories: [.mdm]),

        // MARK: - Accessibility / input helpers

        .init(teamIdentifier: "G43BCU2T37", displayName: "Karabiner-Elements",
              sensitiveCategories: [.accessibility]),
        .init(teamIdentifier: "DAFVSXZ82P", displayName: "BetterTouchTool",
              sensitiveCategories: [.accessibility]),
        .init(teamIdentifier: "QMHRBA9LYL", displayName: "Keyboard Maestro",
              sensitiveCategories: [.accessibility]),

        // MARK: - Known, non-sensitive

        .init(teamIdentifier: "UBF8T346G9", displayName: "Microsoft"),
        .init(teamIdentifier: "JQ525L2MZD", displayName: "Adobe"),
        .init(teamIdentifier: "EQHXZ8M8AV", displayName: "Google"),
        .init(teamIdentifier: "BJ4HAAB9B3", displayName: "Spotify"),
        .init(teamIdentifier: "9JA89QQLNQ", displayName: "Docker"),
        .init(teamIdentifier: "Q9MMAVJVA3", displayName: "Slack"),
        .init(teamIdentifier: "43AQ936H96", displayName: "Zoom"),
        .init(teamIdentifier: "MK7Z27EUNL", displayName: "Mozilla"),
    ])
}
