import Foundation

/// Empty input payload for the MCP `list_profiles` tool.
public struct MCPListProfilesInput: Codable, Sendable, Equatable {
    /// Creates an empty list-profiles input.
    public init() {}
}

/// Short profile description returned by `list_profiles`.
public struct MCPProfileSummary: Codable, Sendable, Equatable {
    /// Profile identifier or display name.
    public let name: String
    /// Categories enabled by the profile.
    public let categories: [String]
    /// User-facing profile description.
    public let description: String

    /// Creates a profile summary row.
    public init(name: String, categories: [String], description: String) {
        self.name = name
        self.categories = categories
        self.description = description
    }
}

/// Complete MCP `list_profiles` response payload.
public struct MCPListProfilesOutput: Codable, Sendable, Equatable {
    /// Profiles available to MCP callers.
    public let profiles: [MCPProfileSummary]
    /// Active profile identifier.
    public let active: String

    /// Creates a list-profiles output payload.
    public init(profiles: [MCPProfileSummary], active: String) {
        self.profiles = profiles
        self.active = active
    }
}
