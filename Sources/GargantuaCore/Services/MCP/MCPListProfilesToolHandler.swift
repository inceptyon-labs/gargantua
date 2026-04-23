import Foundation

// Handler for the MCP `list_profiles` tool. Shapes a `ProfilesSnapshot` into
// the `MCPListProfilesOutput` payload the PRD §7.3 contract promises.
//
// Profiles are surfaced with `MCPProfileSummary.name == CleanupProfile.id`
// (e.g. `"light"`, not `"Light Cleanup"`). Clients can pass the returned
// `name` straight back to the `scan` tool's `profile` argument — keeping
// the two tool contracts self-consistent. Display names remain internal to
// the app.
//
// Production wiring in `Sources/GargantuaMCP/main.swift` feeds this handler
// from `PersistenceController`, so built-in and custom profile identifiers
// are the same values the GUI reads and writes.

/// Combined profile-list snapshot. Bundles the available profiles with the
/// active-profile identifier so the handler takes one injected closure
/// rather than two.
public struct ProfilesSnapshot: Sendable {
    public let profiles: [CleanupProfile]
    /// Identifier of the currently-active profile. Must match one of the
    /// `profiles[].id` values; when no match is found the handler emits
    /// `active: ""` (non-null but empty) rather than lying about a default.
    public let active: String

    public init(profiles: [CleanupProfile], active: String) {
        self.profiles = profiles
        self.active = active
    }
}

/// Tool handler for `list_profiles`.
public struct MCPListProfilesToolHandler: Sendable {

    /// Synchronous profiles provider. Throwing `MCPToolError.invalidParams`
    /// or `.internalError` propagates with the appropriate JSON-RPC code;
    /// any other thrown error is surfaced to the client as a tool-domain
    /// `.failure(...)` result.
    public typealias ProfilesProvider = @Sendable () throws -> ProfilesSnapshot

    private let profilesProvider: ProfilesProvider
    private let log: MCPDispatcherLog?

    public init(
        profilesProvider: @escaping ProfilesProvider,
        log: MCPDispatcherLog? = nil
    ) {
        self.profilesProvider = profilesProvider
        self.log = log
    }

    /// Bridges this handler to the `MCPToolHandler` shape the dispatcher
    /// expects:
    /// `dispatcher.register(tool: .listProfiles, handler: handler.toolHandler)`.
    public var toolHandler: MCPToolHandler {
        let this = self
        return { arguments in try this.handle(arguments) }
    }

    /// Execute the handler against a decoded arguments payload. Exposed for
    /// unit tests that want to bypass the dispatcher.
    public func handle(_ arguments: MCPToolArguments) throws -> MCPToolCallResult {
        // `list_profiles` takes no parameters; decode-round-trip is a cheap
        // schema check that rejects unexpected shapes up front.
        _ = try arguments.decode(MCPListProfilesInput.self)

        let snapshot: ProfilesSnapshot
        do {
            snapshot = try profilesProvider()
        } catch let error as MCPToolError {
            throw error
        } catch {
            log?("list_profiles handler error: \(error)")
            return .failure("List profiles failed: \(MCPEncoding.clientFacingMessage(for: error))")
        }

        let output = Self.makeOutput(from: snapshot)
        let payload = try MCPEncoding.encodeAsJSONAny(output)
        return .structured(payload, summary: Self.summary(for: output))
    }

    // MARK: - Helpers

    static func makeOutput(from snapshot: ProfilesSnapshot) -> MCPListProfilesOutput {
        let summaries = snapshot.profiles.map { profile in
            MCPProfileSummary(
                name: profile.id,
                categories: profile.categories,
                description: profile.description
            )
        }
        // Only surface `active` when it resolves to one of the advertised
        // profiles. Returning a dangling identifier would let clients treat
        // an unsupported profile as selectable and hand it back through
        // `scan.profile`, where the scan handler would then reject it.
        let advertisedIDs = Set(summaries.map(\.name))
        let active = advertisedIDs.contains(snapshot.active) ? snapshot.active : ""
        return MCPListProfilesOutput(profiles: summaries, active: active)
    }

    private static func summary(for output: MCPListProfilesOutput) -> String {
        let names = output.profiles.map(\.name).joined(separator: ", ")
        let active = output.active.isEmpty ? "none" : output.active
        return "\(output.profiles.count) profile(s): \(names). Active: \(active)."
    }
}
