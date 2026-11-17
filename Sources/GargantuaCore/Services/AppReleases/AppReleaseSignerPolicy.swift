import Foundation

/// An update signed by another Developer ID team than the installed copy.
/// The names come from the Apple-issued certificates and are for display;
/// only the Team IDs identify the change.
public struct AppReleaseSignerChange: Codable, Sendable, Equatable {
    public let fromTeamID: String
    public let fromName: String?
    public let toTeamID: String
    public let toName: String?

    public init(fromTeamID: String, fromName: String? = nil, toTeamID: String, toName: String? = nil) {
        self.fromTeamID = fromTeamID
        self.fromName = fromName
        self.toTeamID = toTeamID
        self.toName = toName
    }

    /// `MuseScore (6EPAF2X3PR)`, or the Team ID alone without a name.
    public var fromLabel: String { Self.label(name: fromName, teamID: fromTeamID) }
    public var toLabel: String { Self.label(name: toName, teamID: toTeamID) }

    /// Whether `other` is the same hand-over, whatever names it carries.
    public func isSameChange(as other: AppReleaseSignerChange) -> Bool {
        fromTeamID == other.fromTeamID && toTeamID == other.toTeamID
    }

    private static func label(name: String?, teamID: String) -> String {
        name.map { "\($0) (\(teamID))" } ?? teamID
    }
}

/// Why a change of signer was let through.
public enum AppReleaseSignerBasis: String, Sendable, Equatable {
    /// The bundled catalog lists the hand-over.
    case catalog
    /// The download carries a Sparkle EdDSA signature made with the key the
    /// installed copy publishes, so the previous developer signed it off.
    case updateKey
    /// The user approved this exact hand-over for this app.
    case approved

    var auditNote: String {
        switch self {
        case .catalog: "listed in the catalog"
        case .updateKey: "vouched for by the installed copy's update key"
        case .approved: "approved by the user"
        }
    }
}

/// A change of signer that verification accepted, and why.
public struct AppReleaseAcceptedSignerChange: Sendable, Equatable {
    public let change: AppReleaseSignerChange
    public let basis: AppReleaseSignerBasis

    public init(change: AppReleaseSignerChange, basis: AppReleaseSignerBasis) {
        self.change = change
        self.basis = basis
    }

    /// Shown after the install when the user wasn't the one who allowed it.
    var warning: String? {
        let signedBy = "The new copy is signed by \(change.toLabel), not \(change.fromLabel)."
        switch basis {
        case .catalog: return "\(signedBy) Gargantua's catalog lists this change of developer."
        case .updateKey: return "\(signedBy) The previous developer's update key signed it off."
        case .approved: return nil
        }
    }

    var auditNote: String { "signer \(change.fromTeamID) → \(change.toTeamID), \(basis.auditNote)" }
}

/// Decides whether another team's update may replace an installed app.
public struct AppReleaseSignerPolicy: Sendable {
    private let catalog: AppReleaseCatalog
    /// Bundle ID to the hand-overs the user approved, read at verify time.
    private let approvals: @Sendable () -> [String: [AppReleaseSignerChange]]

    public init(
        catalog: AppReleaseCatalog = AppReleaseCatalog(entries: []),
        approvals: @escaping @Sendable () -> [String: [AppReleaseSignerChange]] = { [:] }
    ) {
        self.catalog = catalog
        self.approvals = approvals
    }

    /// The bundled catalog and the approvals stored in the app's preferences.
    public static let standard = AppReleaseSignerPolicy(
        catalog: .bundled,
        approvals: { AppReleasePreferences.stored().approvedSigners }
    )

    /// - Parameter vouchedByUpdateKey: The download's EdDSA signature
    ///   verified against the installed copy's `SUPublicEDKey`.
    func basis(
        for change: AppReleaseSignerChange,
        bundleID: String,
        vouchedByUpdateKey: Bool
    ) -> AppReleaseSignerBasis? {
        if catalog.successorTeam(bundleID: bundleID, installedTeam: change.fromTeamID) == change.toTeamID {
            return .catalog
        }
        // Sparkle's own rule: an update may change the signing certificate
        // or the update key, never both.
        if vouchedByUpdateKey { return .updateKey }
        if approvals()[bundleID]?.contains(where: change.isSameChange) == true { return .approved }
        return nil
    }
}

public extension AppReleasePreferences {
    /// Records the user's approval of `change` for `bundleID`.
    mutating func approve(_ change: AppReleaseSignerChange, for bundleID: String) {
        var approved = approvedSigners[bundleID] ?? []
        guard !approved.contains(where: change.isSameChange) else { return }
        approved.append(change)
        approvedSigners[bundleID] = approved
    }
}
