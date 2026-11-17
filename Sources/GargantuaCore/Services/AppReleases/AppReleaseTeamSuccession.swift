import Foundation

/// A catalog-declared change of signer: releases of `bundleID` moved from one
/// Developer ID team to another. An update signed by any other team than the
/// installed app's is refused unless the catalog lists the hand-over.
public struct AppReleaseTeamSuccession: Sendable, Equatable, Decodable {
    public let bundleID: String
    public let name: String
    public let fromTeamID: String
    public let toTeamID: String
    public let explanation: String

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case name
        case fromTeamID = "from_team_id"
        case toTeamID = "to_team_id"
        case explanation
    }

    public init(bundleID: String, name: String, fromTeamID: String, toTeamID: String, explanation: String) {
        self.bundleID = bundleID
        self.name = name
        self.fromTeamID = fromTeamID
        self.toTeamID = toTeamID
        self.explanation = explanation
    }

    /// Re-checks what the upstream validator enforces, so a bad snapshot
    /// entry is dropped instead of trusted.
    func validationError() -> String? {
        let teams = [fromTeamID, toTeamID]
        guard teams.allSatisfy({ $0.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil }) else {
            return "\(bundleID): from_team_id and to_team_id must be 10-character Team IDs"
        }
        guard fromTeamID != toTeamID else { return "\(bundleID): from_team_id and to_team_id are the same" }
        guard !bundleID.isEmpty else { return "team_successions: bundle_id is empty" }
        return nil
    }
}

public extension AppReleaseCatalog {
    /// The team that may sign an update of `bundleID` in place of
    /// `installedTeam`, when the catalog declares that hand-over.
    func successorTeam(bundleID: String, installedTeam: String?) -> String? {
        guard let installedTeam else { return nil }
        return successions.first { $0.bundleID == bundleID && $0.fromTeamID == installedTeam }?.toTeamID
    }
}
