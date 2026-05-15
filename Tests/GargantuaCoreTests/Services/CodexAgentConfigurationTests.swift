import Testing
import Foundation
@testable import GargantuaCore

@Suite("CodexAgentConfiguration")
struct CodexAgentConfigurationTests {

    private static func makeDefaults() -> UserDefaults {
        let suiteName = "codex-cfg-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("Default config is disabled with no CLI path and an empty model")
    func defaults() {
        let cfg = CodexAgentConfiguration()
        #expect(cfg.isEnabled == false)
        #expect(cfg.cliPath.isEmpty)
        #expect(cfg.selectedModel.isEmpty)
    }

    @Test("Init trims whitespace on cliPath + selectedModel")
    func trimsWhitespace() {
        let cfg = CodexAgentConfiguration(
            isEnabled: true,
            cliPath: "  /usr/local/bin/codex  ",
            selectedModel: "\n gpt-5-codex \n"
        )
        #expect(cfg.cliPath == "/usr/local/bin/codex")
        #expect(cfg.selectedModel == "gpt-5-codex")
    }

    @Test("normalizedCLIPath expands tildes; nil when empty")
    func tildeExpansion() {
        let configured = CodexAgentConfiguration(cliPath: "~/local/bin/codex")
        let expanded = configured.normalizedCLIPath
        #expect(expanded?.hasPrefix("/") == true)
        #expect(expanded?.contains("local/bin/codex") == true)

        let empty = CodexAgentConfiguration(cliPath: "")
        #expect(empty.normalizedCLIPath == nil)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let original = CodexAgentConfiguration(
            isEnabled: true,
            cliPath: "/opt/bin/codex",
            selectedModel: "gpt-5-codex"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CodexAgentConfiguration.self, from: data)
        #expect(decoded == original)
    }

    @Test("Decoder fills in defaults for missing fields (back-compat)")
    func decoderBackCompat() throws {
        let json = #"{"isEnabled":true}"#
        let decoded = try JSONDecoder().decode(
            CodexAgentConfiguration.self,
            from: Data(json.utf8)
        )
        #expect(decoded.isEnabled == true)
        #expect(decoded.cliPath.isEmpty)
        #expect(decoded.selectedModel.isEmpty)
    }

    @Test("Store load + save round-trip via UserDefaults")
    func storeRoundTrip() {
        let defaults = Self.makeDefaults()
        let store = CodexAgentConfigurationStore(defaults: defaults)

        // Empty: returns defaults.
        #expect(store.load() == CodexAgentConfiguration())

        let cfg = CodexAgentConfiguration(
            isEnabled: true,
            cliPath: "/foo/codex",
            selectedModel: "gpt-5-codex"
        )
        store.save(cfg)
        #expect(store.load() == cfg)
    }
}

@Suite("CodexCLIResolver")
struct CodexCLIResolverTests {

    @Test("Resolver throws cliNotFound when nothing is on PATH")
    func notFoundOnEmptyPath() {
        let resolver = CodexCLIResolver(
            environment: ["PATH": ""],
            fileManager: .default
        )
        #expect(throws: CodexAgentError.cliNotFound) {
            try resolver.resolve(configuration: CodexAgentConfiguration())
        }
    }

    @Test("Resolver uses the configured cliPath when present and executable")
    func usesConfiguredPath() throws {
        // /bin/echo is universally present and executable on macOS.
        let resolver = CodexCLIResolver(
            environment: [:],
            fileManager: .default
        )
        let resolved = try resolver.resolve(configuration: CodexAgentConfiguration(
            cliPath: "/bin/echo"
        ))
        #expect(resolved.path == "/bin/echo")
    }

    @Test("Resolver throws when configured path doesn't exist")
    func missingConfiguredPath() {
        let resolver = CodexCLIResolver(
            environment: [:],
            fileManager: .default
        )
        #expect(throws: CodexAgentError.cliNotFound) {
            try resolver.resolve(configuration: CodexAgentConfiguration(
                cliPath: "/tmp/this-path-does-not-exist-\(UUID().uuidString)"
            ))
        }
    }
}
