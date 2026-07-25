import Foundation
import GargantuaLicensing

/// Detects and (optionally) prunes orphaned `com.apple.Spotlight`
/// `EnabledPreferenceRules` — dead reverse-DNS bundle-id rows left behind in
/// System Settings → Spotlight after an app is uninstalled. macOS never prunes
/// these and offers no UI to remove them.
///
/// Ported from Mole's `feat(optimize): prune orphaned Spotlight search rules`
/// (tw93/Mole#1000). This reclaims no disk space — it is preference hygiene, so
/// it lives outside the file-clean pipeline and is always `review`-gated.
///
/// Safety invariants:
/// - `System.*` and `com.apple.*` rules are never touched.
/// - Only entries that look like third-party bundle ids AND whose app is not
///   installed are dropped.
/// - The destructive rewrite requires a ``DestructiveActionAuthorization`` from
///   `authorizeDestructive` and is a no-op in `dryRun`.
public struct SpotlightOrphanRuleScanner: Sendable {
    private let reader: any SpotlightRulesReading
    private let writer: (any SpotlightRulesWriting)?
    private let resolver: any InstalledAppResolving
    private let authorizeDestructive: @Sendable () async -> DestructiveActionAuthorization?

    /// - Parameter authorizeDestructive: Mints the token `prune()` needs.
    ///   Defaults to refusing, so a scanner assembled without an explicit gate
    ///   can scan but never rewrite; ``live()`` wires the real `LicenseGate`.
    public init(
        reader: any SpotlightRulesReading,
        writer: (any SpotlightRulesWriting)? = nil,
        resolver: any InstalledAppResolving,
        authorizeDestructive: @escaping @Sendable () async -> DestructiveActionAuthorization? = { nil }
    ) {
        self.reader = reader
        self.writer = writer
        self.resolver = resolver
        self.authorizeDestructive = authorizeDestructive
    }

    /// Returns the orphaned rules without modifying anything.
    public func findOrphans() -> [SpotlightOrphanRule] {
        Self.orphans(in: reader.enabledRuleIdentifiers(), resolver: resolver)
    }

    /// Pure classification: which identifiers are removable orphans.
    public static func orphans(
        in identifiers: [String],
        resolver: any InstalledAppResolving
    ) -> [SpotlightOrphanRule] {
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            let rule = SpotlightPreferenceRule(identifier: identifier)
            guard rule.isThirdPartyBundleID else { return nil }
            guard !resolver.isInstalled(bundleID: identifier) else { return nil }
            guard seen.insert(identifier).inserted else { return nil }
            return SpotlightOrphanRule(identifier: identifier)
        }
    }

    /// Result of a prune attempt.
    public struct PruneOutcome: Sendable, Equatable {
        public let removed: [SpotlightOrphanRule]
        public let didWrite: Bool
    }

    public enum PruneError: Error, Sendable, Equatable {
        /// The license gate blocked the destructive rewrite.
        case destructiveActionBlocked
        /// No writer was configured (read-only scanner).
        case noWriter
    }

    /// Computes orphans and rewrites the store to drop them. In `dryRun` mode
    /// nothing is written and the gate is not consulted.
    @discardableResult
    public func prune(dryRun: Bool = false) async throws -> PruneOutcome {
        let identifiers = reader.enabledRuleIdentifiers()
        let orphans = Self.orphans(in: identifiers, resolver: resolver)

        guard !dryRun else {
            return PruneOutcome(removed: orphans, didWrite: false)
        }
        guard !orphans.isEmpty else {
            return PruneOutcome(removed: [], didWrite: false)
        }
        guard let writer else { throw PruneError.noWriter }
        guard let authorization = await authorizeDestructive(),
              authorization.surface == .spotlightOrphanRules else {
            throw PruneError.destructiveActionBlocked
        }

        let drop = Set(orphans.map(\.identifier))
        let kept = identifiers.filter { !drop.contains($0) }
        try writer.write(keptIdentifiers: kept)

        return PruneOutcome(removed: orphans, didWrite: true)
    }
}
