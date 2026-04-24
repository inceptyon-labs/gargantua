import Foundation
import Testing
@testable import GargantuaCore

@Suite("RuleParser")
struct RuleParserTests {
    let parser = RuleParser()

    // MARK: - Happy Path

    @Test("Parses complete rule with all fields")
    func parseCompleteRule() throws {
        let yaml = """
        rules:
          - id: chrome_cache
            name: Chrome Browser Cache
            paths:
              - ~/Library/Caches/Google/Chrome
            pattern: "Cache/*"
            exclude:
              - "*.log"
            skip_if_process_running:
              - com.google.Chrome
            presence_guards:
              - path: Offline Media
            content_guards:
              - path: metadata.json
                contains:
                  - clipboard_history
            match_filters:
              - "mtime > 7d"
            safety: safe
            confidence: 97
            explanation: Browser cache that Chrome rebuilds automatically
            source:
              name: Google Chrome
              bundle_id: com.google.Chrome
              verify_signature: true
            regenerates: true
            regenerate_command: "open -a 'Google Chrome'"
            category: browser_cache
            tags:
              - browser
              - cache
            safety_overrides:
              - condition: "age > 30d"
                safety: safe
                confidence: 95
                explanation_suffix: "Inactive for 30+ days."
                profiles:
                  - developer
                  - deep
        """

        let ruleFile = try parser.parse(yaml: yaml)
        #expect(ruleFile.rules.count == 1)

        let rule = ruleFile.rules[0]
        #expect(rule.id == "chrome_cache")
        #expect(rule.name == "Chrome Browser Cache")
        #expect(rule.paths == ["~/Library/Caches/Google/Chrome"])
        #expect(rule.pattern == "Cache/*")
        #expect(rule.exclude == ["*.log"])
        #expect(rule.skipIfProcessRunning == ["com.google.Chrome"])
        #expect(rule.presenceGuards == [RulePresenceGuard(path: "Offline Media")])
        #expect(rule.contentGuards == [RuleContentGuard(path: "metadata.json", contains: ["clipboard_history"])])
        #expect(rule.matchFilters == ["mtime > 7d"])
        #expect(rule.safety == .safe)
        #expect(rule.confidence == 97)
        #expect(rule.explanation == "Browser cache that Chrome rebuilds automatically")
        #expect(rule.source.name == "Google Chrome")
        #expect(rule.source.bundleID == "com.google.Chrome")
        #expect(rule.source.verifySignature == true)
        #expect(rule.regenerates == true)
        #expect(rule.regenerateCommand == "open -a 'Google Chrome'")
        #expect(rule.category == "browser_cache")
        #expect(rule.tags == ["browser", "cache"])
        #expect(rule.safetyOverrides.count == 1)
        #expect(rule.safetyOverrides[0].condition == "age > 30d")
        #expect(rule.safetyOverrides[0].safety == .safe)
        #expect(rule.safetyOverrides[0].confidence == 95)
        #expect(rule.safetyOverrides[0].explanationSuffix == "Inactive for 30+ days.")
        #expect(rule.safetyOverrides[0].profiles == ["developer", "deep"])
    }

    @Test("Parses multiple rules in one file")
    func parseMultipleRules() throws {
        let yaml = """
        rules:
          - id: chrome_cache
            name: Chrome Cache
            paths: ["~/Library/Caches/Google/Chrome"]
            safety: safe
            confidence: 97
            explanation: Chrome browser cache
            source:
              name: Google Chrome
            category: browser_cache
          - id: safari_cache
            name: Safari Cache
            paths: ["~/Library/Caches/com.apple.Safari"]
            safety: safe
            confidence: 95
            explanation: Safari browser cache
            source:
              name: Safari
              bundle_id: com.apple.Safari
            category: browser_cache
        """

        let ruleFile = try parser.parse(yaml: yaml)
        #expect(ruleFile.rules.count == 2)
        #expect(ruleFile.rules[0].id == "chrome_cache")
        #expect(ruleFile.rules[1].id == "safari_cache")
        #expect(ruleFile.rules[1].source.bundleID == "com.apple.Safari")
    }

    // MARK: - Defaults

    @Test("Missing optional fields get sensible defaults")
    func optionalFieldDefaults() throws {
        let yaml = """
        rules:
          - id: sys_logs
            name: System Logs
            paths: ["/var/log"]
            safety: review
            confidence: 80
            explanation: System log files
            source:
              name: macOS
            category: system_logs
        """

        let rule = try parser.parse(yaml: yaml).rules[0]
        #expect(rule.pattern == nil)
        #expect(rule.exclude.isEmpty)
        #expect(rule.tags.isEmpty)
        #expect(rule.regenerates == false)
        #expect(rule.regenerateCommand == nil)
        #expect(rule.safetyOverrides.isEmpty)
        #expect(rule.skipIfProcessRunning.isEmpty)
        #expect(rule.presenceGuards.isEmpty)
        #expect(rule.contentGuards.isEmpty)
        #expect(rule.matchFilters.isEmpty)
        #expect(rule.source.bundleID == nil)
        #expect(rule.source.verifySignature == false)
    }

    // MARK: - Safety Levels

    @Test("Parses all three safety levels")
    func allSafetyLevels() throws {
        let yaml = """
        rules:
          - id: r1
            name: Safe Rule
            paths: ["/a"]
            safety: safe
            confidence: 99
            explanation: safe
            source: { name: test }
            category: test
          - id: r2
            name: Review Rule
            paths: ["/b"]
            safety: review
            confidence: 70
            explanation: review
            source: { name: test }
            category: test
          - id: r3
            name: Protected Rule
            paths: ["/c"]
            safety: protected
            confidence: 50
            explanation: protected
            source: { name: test }
            category: test
        """

        let rules = try parser.parse(yaml: yaml).rules
        #expect(rules[0].safety == .safe)
        #expect(rules[1].safety == .review)
        #expect(rules[2].safety == .protected_)
    }

    // MARK: - Error Handling

    @Test("Reports error for invalid YAML")
    func invalidYAML() {
        let yaml = "{{{{not yaml at all"

        #expect(throws: RuleParseError.self) {
            try parser.parse(yaml: yaml, filePath: "bad.yaml")
        }
    }

    @Test("Reports error for missing rules key")
    func missingRulesKey() {
        let yaml = """
        something_else:
          - id: test
        """

        #expect(throws: RuleParseError.self) {
            try parser.parse(yaml: yaml, filePath: "no_rules.yaml")
        }
    }

    @Test("Reports error for missing required field")
    func missingRequiredField() {
        let yaml = """
        rules:
          - id: test_rule
            name: Test
            paths: ["/test"]
            safety: safe
            confidence: 90
            explanation: test
            source: { name: test }
        """
        // missing 'category'

        #expect(throws: RuleParseError.self) {
            try parser.parse(yaml: yaml, filePath: "missing_field.yaml")
        }
    }

    @Test("Reports error for invalid safety value")
    func invalidSafetyValue() {
        let yaml = """
        rules:
          - id: test_rule
            name: Test
            paths: ["/test"]
            safety: dangerous
            confidence: 90
            explanation: test
            source: { name: test }
            category: test
        """

        #expect(throws: RuleParseError.self) {
            try parser.parse(yaml: yaml, filePath: "bad_safety.yaml")
        }
    }

    @Test("Error description includes file path")
    func errorIncludesFilePath() {
        let yaml = "not: valid"

        do {
            _ = try parser.parse(yaml: yaml, filePath: "cleanup_rules/browser/chrome.yaml")
            Issue.record("Expected error")
        } catch {
            let description = "\(error)"
            #expect(description.contains("cleanup_rules/browser/chrome.yaml"))
        }
    }
}

@Suite("RuleLoader")
struct RuleLoaderTests {
    let loader = RuleLoader()

    @Test("Loads rules from directory with YAML files")
    func loadFromDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let browserDir = tempDir.appendingPathComponent("browser")
        try FileManager.default.createDirectory(at: browserDir, withIntermediateDirectories: true)

        let chromeYAML = """
        rules:
          - id: chrome_cache
            name: Chrome Cache
            paths: ["~/Library/Caches/Google/Chrome"]
            safety: safe
            confidence: 97
            explanation: Chrome cache
            source: { name: Google Chrome }
            category: browser_cache
        """
        try chromeYAML.write(to: browserDir.appendingPathComponent("chrome.yaml"), atomically: true, encoding: .utf8)

        let safariYAML = """
        rules:
          - id: safari_cache
            name: Safari Cache
            paths: ["~/Library/Caches/com.apple.Safari"]
            safety: safe
            confidence: 95
            explanation: Safari cache
            source: { name: Safari }
            category: browser_cache
        """
        try safariYAML.write(to: browserDir.appendingPathComponent("safari.yml"), atomically: true, encoding: .utf8)

        let result = try loader.loadRules(from: tempDir)
        #expect(result.rules.count == 2)
        #expect(result.filesLoaded == 2)
        #expect(result.isClean)
    }

    @Test("Returns empty result for nonexistent directory")
    func nonexistentDirectory() throws {
        let result = try loader.loadRules(from: URL(fileURLWithPath: "/nonexistent/path"))
        #expect(result.rules.isEmpty)
        #expect(result.errors.isEmpty)
        #expect(result.filesLoaded == 0)
    }

    @Test("Collects errors but continues loading other files")
    func partialLoadWithErrors() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gargantua-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let goodYAML = """
        rules:
          - id: good_rule
            name: Good Rule
            paths: ["/good"]
            safety: safe
            confidence: 99
            explanation: works
            source: { name: test }
            category: test
        """
        try goodYAML.write(to: tempDir.appendingPathComponent("good.yaml"), atomically: true, encoding: .utf8)

        let badYAML = "{{{{not yaml"
        try badYAML.write(to: tempDir.appendingPathComponent("bad.yaml"), atomically: true, encoding: .utf8)

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

        try "not a yaml rule".write(to: tempDir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try "{}".write(to: tempDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let result = try loader.loadRules(from: tempDir)
        #expect(result.rules.isEmpty)
        #expect(result.filesLoaded == 0)
    }
}
