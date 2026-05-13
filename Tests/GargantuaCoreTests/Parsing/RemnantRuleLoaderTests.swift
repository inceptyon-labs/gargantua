import Foundation
import Testing
@testable import GargantuaCore

@Suite("RemnantRuleLoader")
struct RemnantRuleLoaderTests {
    let loader = RemnantRuleLoader()

    @Test("Loads remnant rules from directory with YAML files")
    func loadFromDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let nestedDir = tempDir.appendingPathComponent("vendor")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)

        let genericYAML = """
        remnant_rules:
          - id: generic_caches
            name: Caches
            category: caches
            path_templates:
              - "~/Library/Caches/{bundleID}"
            confidence: 99
            explanation: Disposable cache data.
            source:
              name: "{appName}"
        """
        try genericYAML.write(
            to: tempDir.appendingPathComponent("generic.yaml"),
            atomically: true, encoding: .utf8
        )

        let slackYAML = """
        remnant_rules:
          - id: slack_webdata
            name: Slack WebKit storage
            category: web_data
            path_templates:
              - "~/Library/WebKit/{bundleID}"
            confidence: 96
            explanation: WebKit storage regenerated on next launch.
            source:
              name: Slack
              bundle_id: com.tinyspeck.slackmacgap
        """
        try slackYAML.write(
            to: nestedDir.appendingPathComponent("slack.yml"),
            atomically: true, encoding: .utf8
        )

        let result = try loader.loadRules(from: tempDir)
        #expect(result.rules.count == 2)
        #expect(result.filesLoaded == 2)
        #expect(result.isClean)
        #expect(result.errors.isEmpty)

        let ids = Set(result.rules.map(\.id))
        #expect(ids == ["generic_caches", "slack_webdata"])
    }

    @Test("Returns empty result for nonexistent directory")
    func nonexistentDirectory() throws {
        let result = try loader.loadRules(from: URL(fileURLWithPath: "/nonexistent/remnant-rules-path"))
        #expect(result.rules.isEmpty)
        #expect(result.errors.isEmpty)
        #expect(result.filesLoaded == 0)
        #expect(result.isClean)
    }

    @Test("Collects errors but continues loading other files")
    func partialLoadWithErrors() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let goodYAML = """
        remnant_rules:
          - id: good_rule
            name: Good Rule
            category: caches
            path_templates: ["~/Library/Caches/{bundleID}"]
            confidence: 90
            explanation: works
            source:
              name: test
        """
        try goodYAML.write(
            to: tempDir.appendingPathComponent("good.yaml"),
            atomically: true, encoding: .utf8
        )

        let badYAML = "{{{{not yaml"
        try badYAML.write(
            to: tempDir.appendingPathComponent("bad.yaml"),
            atomically: true, encoding: .utf8
        )

        let result = try loader.loadRules(from: tempDir)
        #expect(result.rules.count == 1)
        #expect(result.rules[0].id == "good_rule")
        #expect(result.errors.count == 1)
        #expect(result.filesLoaded == 1)
        #expect(!result.isClean)
    }

    @Test("Ignores non-YAML files")
    func ignoresNonYAML() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "not a yaml rule".write(
            to: tempDir.appendingPathComponent("readme.txt"),
            atomically: true, encoding: .utf8
        )
        try "{}".write(
            to: tempDir.appendingPathComponent("config.json"),
            atomically: true, encoding: .utf8
        )

        let result = try loader.loadRules(from: tempDir)
        #expect(result.rules.isEmpty)
        #expect(result.filesLoaded == 0)
        #expect(result.errors.isEmpty)
    }
}
