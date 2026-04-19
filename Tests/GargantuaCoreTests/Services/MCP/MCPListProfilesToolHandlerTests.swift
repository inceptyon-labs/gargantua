import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP list_profiles tool handler")
struct MCPListProfilesToolHandlerTests {

    // MARK: Fixtures

    private static let serverInfo = MCPServerInfo(name: "gargantua", version: "0.0.1")

    private static let sampleProfiles: [CleanupProfile] = [
        CleanupProfile(
            id: "light",
            name: "Light Cleanup",
            description: "Browser caches + system logs + Trash + installers",
            categories: ["browser_cache", "system_logs", "trash", "installers"]
        ),
        CleanupProfile(
            id: "developer",
            name: "Developer",
            description: "All caches + dev artifacts",
            categories: ["dev_artifacts", "docker"]
        ),
    ]

    private func handler(
        provider: @escaping @Sendable () throws -> ProfilesSnapshot
    ) -> MCPListProfilesToolHandler {
        MCPListProfilesToolHandler(profilesProvider: provider)
    }

    private static let emptyArguments = MCPToolArguments([:])

    private static func decodeOutput(_ result: MCPToolCallResult) throws -> MCPListProfilesOutput {
        let payload = try #require(result.structuredContent, "structured content missing")
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(MCPListProfilesOutput.self, from: data)
    }

    // MARK: Happy path

    @Test("maps snapshot profiles into MCPListProfilesOutput in order")
    func mapsProfilesInOrder() throws {
        let subject = handler(provider: {
            ProfilesSnapshot(profiles: Self.sampleProfiles, active: "light")
        })
        let result = try subject.handle(Self.emptyArguments)
        #expect(result.isError == false)
        let output = try Self.decodeOutput(result)
        #expect(output.profiles.count == 2)
        #expect(output.profiles[0].name == "light")
        #expect(output.profiles[1].name == "developer")
    }

    @Test("profile.name on the wire is the id, not the display name")
    func nameIsIdNotDisplayName() throws {
        let subject = handler(provider: {
            ProfilesSnapshot(profiles: Self.sampleProfiles, active: "light")
        })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        // "Light Cleanup" is the display name; the wire contract uses the id
        // so clients can round-trip it through scan.profile.
        #expect(!output.profiles.contains { $0.name == "Light Cleanup" })
        #expect(output.profiles.contains { $0.name == "light" })
    }

    @Test("profile categories and description pass through verbatim")
    func categoriesAndDescriptionPassThrough() throws {
        let subject = handler(provider: {
            ProfilesSnapshot(profiles: Self.sampleProfiles, active: "light")
        })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        let light = try #require(output.profiles.first { $0.name == "light" })
        #expect(light.categories == ["browser_cache", "system_logs", "trash", "installers"])
        #expect(light.description.contains("Browser caches"))
    }

    @Test("active defaults to the supplied identifier when it matches a profile")
    func activeMatches() throws {
        let subject = handler(provider: {
            ProfilesSnapshot(profiles: Self.sampleProfiles, active: "developer")
        })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        #expect(output.active == "developer")
    }

    @Test("active falls back to empty string when identifier is not advertised")
    func activeDanglingReturnsEmpty() throws {
        // Provider returns an `active` value that doesn't match any of the
        // returned profiles. The handler must not surface that dangling id
        // as selectable — clients would hand it back through scan.profile
        // where it would be rejected.
        let subject = handler(provider: {
            ProfilesSnapshot(profiles: Self.sampleProfiles, active: "custom")
        })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        #expect(output.active == "")
    }

    @Test("empty profiles list is a valid payload")
    func emptyProfiles() throws {
        let subject = handler(provider: {
            ProfilesSnapshot(profiles: [], active: "")
        })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        #expect(output.profiles.isEmpty)
        #expect(output.active == "")
    }

    @Test("default wiring surfaces all three built-ins with active: light")
    func builtInsDefault() throws {
        // The production wiring in main.swift defaults to
        // `CleanupProfile.builtIn` + `active: "light"`. Mirror that here to
        // guard against accidental shape drift.
        let subject = handler(provider: {
            ProfilesSnapshot(profiles: CleanupProfile.builtIn, active: "light")
        })
        let output = try Self.decodeOutput(try subject.handle(Self.emptyArguments))
        #expect(output.active == "light")
        let names = Set(output.profiles.map(\.name))
        #expect(names == ["developer", "light", "deep"])
    }

    @Test("wire envelope uses expected keys for PRD contract")
    func wireKeys() throws {
        let subject = handler(provider: {
            ProfilesSnapshot(profiles: Self.sampleProfiles, active: "light")
        })
        let payload = try #require(try subject.handle(Self.emptyArguments).structuredContent)
        guard case .object(let root) = payload else {
            Issue.record("payload should be object")
            return
        }
        #expect(root["profiles"] != nil)
        #expect(root["active"] != nil)
    }

    @Test("result is .structured with text summary listing profile names")
    func structuredResultShape() throws {
        let subject = handler(provider: {
            ProfilesSnapshot(profiles: Self.sampleProfiles, active: "light")
        })
        let result = try subject.handle(Self.emptyArguments)
        #expect(result.isError == false)
        #expect(result.structuredContent != nil)
        guard case .text(let summary) = result.content.first else {
            Issue.record("content[0] should be text")
            return
        }
        #expect(summary.contains("light"))
        #expect(summary.contains("developer"))
        #expect(summary.contains("Active: light"))
    }

    @Test("extra unknown fields on list_profiles arguments are ignored")
    func extraFieldsIgnored() throws {
        let subject = handler(provider: {
            ProfilesSnapshot(profiles: Self.sampleProfiles, active: "light")
        })
        let result = try subject.handle(MCPToolArguments([
            "foo": .string("bar"),
        ]))
        #expect(result.isError == false)
    }

    // MARK: Provider errors

    @Test("provider throwing MCPToolError.invalidParams rethrows for dispatcher")
    func providerInvalidParamsRethrown() throws {
        let subject = handler(provider: {
            throw MCPToolError.invalidParams("bad profile source")
        })
        do {
            _ = try subject.handle(Self.emptyArguments)
            Issue.record("handler should have thrown")
        } catch MCPToolError.invalidParams(let message) {
            #expect(message == "bad profile source")
        }
    }

    @Test("provider throwing a LocalizedError surfaces description in .failure")
    func providerLocalizedError() throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "profile store unavailable" }
        }
        let subject = handler(provider: { throw Boom() })
        let result = try subject.handle(Self.emptyArguments)
        #expect(result.isError == true)
        guard case .text(let message) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(message.contains("List profiles failed"))
        #expect(message.contains("profile store unavailable"))
    }

    @Test("provider throwing a plain Error does not leak its reflection")
    func providerPlainErrorSanitized() throws {
        struct SecretLeak: Error {
            let secret = "/private/credentials"
        }
        let captured = ListProfilesCapturedLog()
        let subject = MCPListProfilesToolHandler(
            profilesProvider: { throw SecretLeak() },
            log: { captured.append($0) }
        )
        let result = try subject.handle(Self.emptyArguments)
        #expect(result.isError == true)
        guard case .text(let message) = result.content.first else {
            Issue.record("expected text content")
            return
        }
        #expect(!message.contains("SecretLeak"))
        #expect(!message.contains("/private/credentials"))
        #expect(message.contains("internal error"))
        #expect(captured.joined.contains("SecretLeak"))
    }

    // MARK: Dispatcher integration

    @Test("registering with dispatcher routes tools/call to the handler")
    func dispatcherIntegration() throws {
        let dispatcher = MCPRequestDispatcher(serverInfo: Self.serverInfo)
        let subject = handler(provider: {
            ProfilesSnapshot(profiles: Self.sampleProfiles, active: "light")
        })
        dispatcher.register(tool: .listProfiles, handler: subject.toolHandler)

        let request = MCPRequest(
            id: .int(1),
            method: "tools/call",
            params: .object([
                "name": .string("list_profiles"),
                "arguments": .object([:]),
            ])
        )
        let response = try #require(dispatcher.dispatch(request))
        #expect(response.error == nil)
        guard case .object(let envelope) = response.result else {
            Issue.record("result should be an object")
            return
        }
        #expect(envelope["content"] != nil)
        #expect(envelope["structuredContent"] != nil)
        #expect(envelope["isError"] == nil)
    }

    @Test("dispatcher reports tool-domain failure as isError=true, not JSON-RPC error")
    func dispatcherPropagatesDomainFailure() throws {
        struct Boom: Error {}
        let dispatcher = MCPRequestDispatcher(serverInfo: Self.serverInfo)
        let subject = handler(provider: { throw Boom() })
        dispatcher.register(tool: .listProfiles, handler: subject.toolHandler)

        let request = MCPRequest(
            id: .int(2),
            method: "tools/call",
            params: .object([
                "name": .string("list_profiles"),
                "arguments": .object([:]),
            ])
        )
        let response = try #require(dispatcher.dispatch(request))
        #expect(response.error == nil)
        guard case .object(let envelope) = response.result else {
            Issue.record("result should be an object")
            return
        }
        #expect(envelope["isError"] == .bool(true))
    }
}

// MARK: - Test capture helpers

private final class ListProfilesCapturedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var joined: String {
        lock.lock()
        defer { lock.unlock() }
        return entries.joined(separator: "\n")
    }
}
