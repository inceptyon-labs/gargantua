import Foundation
import Testing
@testable import GargantuaCore

@Suite("RemnantRuleParser")
struct RemnantRuleParserTests {
    let parser = RemnantRuleParser()

    // MARK: - Happy Path

    @Test("Parses a complete remnant rule with every field set")
    func parseCompleteRule() throws {
        let yaml = """
        remnant_rules:
          - id: slack_webdata
            name: Slack WebKit storage
            category: web_data
            path_templates:
              - "~/Library/WebKit/{bundleID}"
            pattern: "*.sqlite"
            exclude:
              - "**/backup/**"
            safety: safe
            confidence: 96
            explanation: WebKit storage regenerated on next launch.
            source:
              name: Slack
              bundle_id: com.tinyspeck.slackmacgap
              verify_signature: true
            applies_to:
              bundle_ids:
                - com.tinyspeck.slackmacgap
              exclude_bundle_ids: []
            regenerates: true
            tags:
              - slack
              - webkit
        """

        let file = try parser.parse(yaml: yaml)
        #expect(file.rules.count == 1)

        let rule = file.rules[0]
        #expect(rule.id == "slack_webdata")
        #expect(rule.name == "Slack WebKit storage")
        #expect(rule.category == .webData)
        #expect(rule.pathTemplates == ["~/Library/WebKit/{bundleID}"])
        #expect(rule.pattern == "*.sqlite")
        #expect(rule.exclude == ["**/backup/**"])
        #expect(rule.safety == .safe)
        #expect(rule.confidence == 96)
        #expect(rule.explanation.contains("WebKit"))
        #expect(rule.source.name == "Slack")
        #expect(rule.source.bundleID == "com.tinyspeck.slackmacgap")
        #expect(rule.source.verifySignature == true)
        #expect(rule.appliesTo?.bundleIDs == ["com.tinyspeck.slackmacgap"])
        #expect(rule.regenerates == true)
        #expect(rule.tags == ["slack", "webkit"])
    }

    @Test("Parses multiple rules in a single file")
    func parseMultipleRules() throws {
        let yaml = """
        remnant_rules:
          - id: r1
            name: Caches
            category: caches
            path_templates: ["~/Library/Caches/{bundleID}"]
            confidence: 99
            explanation: disposable
            source: { name: "{appName}" }
          - id: r2
            name: Logs
            category: logs
            path_templates: ["~/Library/Logs/{appName}"]
            confidence: 98
            explanation: disposable logs
            source: { name: "{appName}" }
        """
        let rules = try parser.parse(yaml: yaml).rules
        #expect(rules.count == 2)
        #expect(rules[0].category == .caches)
        #expect(rules[1].category == .logs)
    }

    // MARK: - Defaults

    @Test("Omitting safety inherits category default at parse time")
    func safetyDefaultsFromCategory() throws {
        let yaml = """
        remnant_rules:
          - id: r
            name: n
            category: launch_daemons
            path_templates: ["/Library/LaunchDaemons/{bundleID}.plist"]
            confidence: 80
            explanation: daemon
            source: { name: test }
        """
        let rule = try parser.parse(yaml: yaml).rules[0]
        #expect(rule.safety == .protected_)
    }

    @Test("Optional fields get sensible defaults")
    func optionalDefaults() throws {
        let yaml = """
        remnant_rules:
          - id: r
            name: n
            category: caches
            path_templates: ["~/Library/Caches/{bundleID}"]
            confidence: 90
            explanation: e
            source: { name: test }
        """
        let rule = try parser.parse(yaml: yaml).rules[0]
        #expect(rule.pattern == nil)
        #expect(rule.exclude.isEmpty)
        #expect(rule.tags.isEmpty)
        #expect(rule.regenerates == false)
        #expect(rule.appliesTo == nil)
        #expect(rule.source.bundleID == nil)
        #expect(rule.source.verifySignature == false)
    }

    @Test("applies_to with only exclude_bundle_ids produces a deny-list scope")
    func scopeExcludeOnly() throws {
        let yaml = """
        remnant_rules:
          - id: r
            name: n
            category: caches
            path_templates: ["~/Library/Caches/{bundleID}"]
            confidence: 90
            explanation: e
            source: { name: test }
            applies_to:
              exclude_bundle_ids:
                - com.apple.Finder
        """
        let rule = try parser.parse(yaml: yaml).rules[0]
        #expect(rule.appliesTo?.bundleIDs == [])
        #expect(rule.appliesTo?.excludeBundleIDs == ["com.apple.Finder"])
    }

    // MARK: - Errors

    @Test("Invalid YAML raises invalidYAML")
    func invalidYAML() {
        let yaml = "{{{not yaml"
        #expect(throws: RemnantRuleParseError.self) {
            try parser.parse(yaml: yaml, filePath: "bad.yaml")
        }
    }

    @Test("Missing top-level remnant_rules key raises an error")
    func missingRulesKey() {
        let yaml = """
        rules:
          - id: wrong_key
        """
        #expect(throws: RemnantRuleParseError.self) {
            try parser.parse(yaml: yaml, filePath: "wrong_key.yaml")
        }
    }

    @Test("Missing a required field raises missingField")
    func missingField() {
        let yaml = """
        remnant_rules:
          - id: r
            name: n
            category: caches
            path_templates: ["~/Library/Caches/{bundleID}"]
            confidence: 90
            source: { name: test }
        """ // missing explanation

        #expect(throws: RemnantRuleParseError.self) {
            try parser.parse(yaml: yaml, filePath: "missing.yaml")
        }
    }

    @Test("Invalid category value raises invalidValue")
    func invalidCategory() {
        let yaml = """
        remnant_rules:
          - id: r
            name: n
            category: not_a_real_category
            path_templates: ["/x"]
            confidence: 90
            explanation: e
            source: { name: test }
        """
        #expect(throws: RemnantRuleParseError.self) {
            try parser.parse(yaml: yaml, filePath: "bad_category.yaml")
        }
    }

    @Test("Invalid safety value raises invalidValue")
    func invalidSafety() {
        let yaml = """
        remnant_rules:
          - id: r
            name: n
            category: caches
            path_templates: ["/x"]
            safety: dangerous
            confidence: 90
            explanation: e
            source: { name: test }
        """
        #expect(throws: RemnantRuleParseError.self) {
            try parser.parse(yaml: yaml, filePath: "bad_safety.yaml")
        }
    }

    @Test("Error description includes the file path")
    func errorIncludesPath() {
        let yaml = "not: valid"
        do {
            _ = try parser.parse(yaml: yaml, filePath: "uninstall_rules/default.yaml")
            Issue.record("Expected error")
        } catch {
            #expect("\(error)".contains("uninstall_rules/default.yaml"))
        }
    }

    // MARK: - Bundled default_remnants.yaml

    @Test("Bundled default_remnants.yaml parses cleanly")
    func bundledDefaultsParse() throws {
        guard let url = Bundle.module.url(
            forResource: "default_remnants",
            withExtension: "yaml",
            subdirectory: "uninstall_rules"
        ) else {
            Issue.record("default_remnants.yaml not bundled")
            return
        }
        let yaml = try String(contentsOf: url, encoding: .utf8)
        let file = try parser.parse(yaml: yaml, filePath: url.path)

        // At least one rule per "safe post-uninstall" category.
        let categories = Set(file.rules.map(\.category))
        #expect(categories.contains(.supportFiles))
        #expect(categories.contains(.caches))
        #expect(categories.contains(.preferences))
        #expect(categories.contains(.launchAgents))
        #expect(categories.contains(.launchDaemons))
        #expect(categories.contains(.logs))

        // Every rule must declare at least one path template.
        for rule in file.rules {
            #expect(!rule.pathTemplates.isEmpty)
        }
    }
}

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
