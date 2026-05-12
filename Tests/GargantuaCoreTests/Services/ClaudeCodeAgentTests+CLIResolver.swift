import Foundation
import Testing
@testable import GargantuaCore

extension ClaudeCodeAgentTests {
    @Test("CLI resolver uses configured executable path")
    func cliResolverUsesConfiguredPath() throws {
        let executable = try makeExecutable(named: "claude")
        let configuration = ClaudeCodeAgentConfiguration(isEnabled: true, cliPath: executable.path)
        let resolved = try ClaudeCodeCLIResolver(environment: [:]).resolve(configuration: configuration)

        #expect(resolved == executable)
    }

    @Test("CLI resolver falls back to PATH")
    func cliResolverFallsBackToPath() throws {
        let executable = try makeExecutable(named: "claude")
        let resolver = ClaudeCodeCLIResolver(environment: [
            "PATH": executable.deletingLastPathComponent().path,
        ])

        let resolved = try resolver.resolve(configuration: ClaudeCodeAgentConfiguration(isEnabled: true))

        #expect(resolved == executable)
    }

    @Test("Configuration decodes older stored payloads with scheduled audits off")
    func configurationDecodesOlderPayloads() throws {
        let data = Data(#"{"isEnabled":true,"cliPath":"/bin/claude","maxTurns":3,"allowDestructiveMCPTools":true}"#.utf8)
        let configuration = try JSONDecoder().decode(ClaudeCodeAgentConfiguration.self, from: data)

        #expect(configuration.isEnabled)
        #expect(configuration.runAfterScheduledScans == false)
    }
}
