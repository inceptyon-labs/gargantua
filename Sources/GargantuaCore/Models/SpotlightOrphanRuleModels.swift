import Foundation

/// A single entry in the `com.apple.Spotlight` `EnabledPreferenceRules` store.
/// Entries are keyed by an identifier: either a reverse-DNS app bundle id
/// (e.g. `com.figma.Desktop`) or a system rule (`System.*`, `com.apple.*`).
public struct SpotlightPreferenceRule: Sendable, Equatable {
    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }

    /// System and first-party rules are never candidates for removal.
    public var isSystemRule: Bool {
        identifier.hasPrefix("System.")
            || identifier == "System"
            || identifier.hasPrefix("com.apple.")
    }

    /// A removable candidate must look like a third-party app bundle id:
    /// reverse-DNS (`a.b[.c…]`), not a filesystem path, not a system rule.
    public var isThirdPartyBundleID: Bool {
        guard !isSystemRule else { return false }
        guard !identifier.contains("/"), !identifier.hasPrefix(".") else { return false }
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { ch in
                ch.isLetter || ch.isNumber || ch == "-" || ch == "_"
            }
        }
    }
}

/// An orphaned Spotlight rule: a third-party bundle id whose app is gone.
public struct SpotlightOrphanRule: Sendable, Equatable, Identifiable {
    public let identifier: String
    public var id: String { identifier }

    public init(identifier: String) {
        self.identifier = identifier
    }
}

/// Reads the enabled Spotlight preference-rule identifiers.
public protocol SpotlightRulesReading: Sendable {
    func enabledRuleIdentifiers() -> [String]
}

/// Rewrites the enabled Spotlight preference rules to a filtered set.
public protocol SpotlightRulesWriting: Sendable {
    /// Persist exactly `keptIdentifiers`, dropping everything else.
    func write(keptIdentifiers: [String]) throws
}

/// Resolves whether a bundle id corresponds to an app installed on this Mac.
public protocol InstalledAppResolving: Sendable {
    func isInstalled(bundleID: String) -> Bool
}

/// Installed-app resolution plus vendor-prefix queries, for deciding whether
/// a background item's owning app is still on disk.
public protocol OwningAppResolving: InstalledAppResolving {
    /// `true` when ANY installed app's bundle identifier starts with
    /// `bundleIDPrefix` (e.g. "com.valvesoftware.").
    func isAnyAppInstalled(bundleIDPrefix: String) -> Bool
    /// `true` when the resolver's discovery layers are healthy enough that a
    /// miss can be trusted as "the app is gone" rather than "we can't see it"
    /// (e.g. Spotlight indexing is disabled, so `mdfind` returns nothing for
    /// apps that are on disk). Callers must treat a miss as *unknown* when
    /// this is `false` — absence evidence gates a safe-to-remove rating.
    func canConfirmAppAbsence() -> Bool
}
