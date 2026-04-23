import Foundation

/// Profile lookup surface shared by MCP handlers.
///
/// The catalog is intentionally value-typed: production builds it from
/// `PersistenceController`, while tests can provide an in-memory set of
/// profiles without touching SwiftData. Explicit unknown IDs are rejected;
/// omitted IDs resolve to the active profile, falling back only when the
/// persisted active setting is dangling.
public struct MCPProfileCatalog: Sendable {
    public let profiles: [CleanupProfile]
    public let activeProfileID: String
    public let fallbackProfileID: String

    public init(
        profiles: [CleanupProfile],
        activeProfileID: String,
        fallbackProfileID: String = "light"
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.fallbackProfileID = fallbackProfileID
    }

    public var snapshot: ProfilesSnapshot {
        ProfilesSnapshot(profiles: profiles, active: activeProfileID)
    }

    public func resolve(_ requestedID: String?) throws -> CleanupProfile {
        if let requestedID {
            let id = requestedID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, let profile = profile(id: id) else {
                throw MCPToolError.invalidParams(Self.unknownProfileMessage(
                    requestedID,
                    availableIDs: availableProfileIDs
                ))
            }
            return profile
        }

        if let active = profile(id: activeProfileID) {
            return active
        }
        if let fallback = profile(id: fallbackProfileID) {
            return fallback
        }

        throw MCPToolError.internalError(
            "No available cleanup profile matches active '\(activeProfileID)' "
            + "or fallback '\(fallbackProfileID)'."
        )
    }

    private func profile(id: String) -> CleanupProfile? {
        profiles.first { $0.id == id }
    }

    private var availableProfileIDs: [String] {
        profiles.map(\.id).sorted()
    }

    private static func unknownProfileMessage(
        _ requestedID: String,
        availableIDs: [String]
    ) -> String {
        let id = requestedID.trimmingCharacters(in: .whitespacesAndNewlines)
        let renderedID = id.isEmpty ? requestedID : id
        guard !availableIDs.isEmpty else {
            return "Unknown profile '\(renderedID)'. No cleanup profiles are currently available."
        }
        return "Unknown profile '\(renderedID)'. "
            + "Use list_profiles and pass one of: \(availableIDs.joined(separator: ", "))."
    }
}
