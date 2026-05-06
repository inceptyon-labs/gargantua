import Foundation
import Testing
@testable import GargantuaCore

@Suite("CommandActionRuleParser")
struct CommandActionRuleParserTests {
    let parser = CommandActionRuleParser()

    // MARK: - Happy path

    @Test("Parses a complete command-action rule")
    func parseCompleteRule() throws {
        let yaml = """
        rules:
          - id: simctl_delete_unavailable
            name: Xcode Simulator (orphaned runtimes)
            tool: xcrun
            arguments:
              - simctl
              - delete
              - unavailable
            dry_run_arguments:
              - simctl
              - list
              - --json
            safety: safe
            confidence: 95
            explanation: Removes simulator runtimes Xcode has marked as unavailable.
            category: developer_tool_command
            regenerates: true
            regenerate_command: "Xcode → Settings → Components"
            affected_roots:
              - "~/Library/Developer/CoreSimulator/Devices"
            preconditions:
              timeout_seconds: 90
            source:
              name: Xcode
              bundle_id: com.apple.dt.Xcode
              verify_signature: false
            tags:
              - xcode
              - simulator
        """

        let file = try parser.parse(yaml: yaml)
        #expect(file.rules.count == 1)

        let rule = file.rules[0]
        #expect(rule.id == "simctl_delete_unavailable")
        #expect(rule.name == "Xcode Simulator (orphaned runtimes)")
        #expect(rule.tool == "xcrun")
        #expect(rule.arguments == ["simctl", "delete", "unavailable"])
        #expect(rule.dryRunArguments == ["simctl", "list", "--json"])
        #expect(rule.safety == .safe)
        #expect(rule.confidence == 95)
        #expect(rule.explanation == "Removes simulator runtimes Xcode has marked as unavailable.")
        #expect(rule.category == "developer_tool_command")
        #expect(rule.regenerates == true)
        #expect(rule.regenerateCommand == "Xcode → Settings → Components")
        #expect(rule.affectedRoots == ["~/Library/Developer/CoreSimulator/Devices"])
        #expect(rule.preconditions.timeoutSeconds == 90)
        #expect(rule.source.name == "Xcode")
        #expect(rule.source.bundleID == "com.apple.dt.Xcode")
        #expect(rule.tags == ["xcode", "simulator"])
        #expect(rule.commandDisplay == "xcrun simctl delete unavailable")
    }

    @Test("Defaults preconditions and optional fields when omitted")
    func parseRuleWithDefaults() throws {
        let yaml = """
        rules:
          - id: minimal
            name: Minimal rule
            tool: pnpm
            arguments:
              - store
              - prune
            safety: review
            confidence: 80
            explanation: Bare-minimum rule for default coverage.
            category: developer_tool_command
            source:
              name: pnpm
        """

        let file = try parser.parse(yaml: yaml)
        let rule = try #require(file.rules.first)
        #expect(rule.dryRunArguments == nil)
        #expect(rule.regenerates == false)
        #expect(rule.regenerateCommand == nil)
        #expect(rule.affectedRoots == [])
        #expect(rule.preconditions.timeoutSeconds == 60)
        #expect(rule.tags == [])
    }

    // MARK: - Trust Layer guards

    @Test("Rejects safety: protected because command rules cannot be protected")
    func rejectsProtectedSafety() throws {
        let yaml = """
        rules:
          - id: bad
            name: Bad rule
            tool: docker
            arguments:
              - system
              - prune
            safety: protected
            confidence: 90
            explanation: Should never parse — protected is not allowed for command rules.
            category: developer_tool_command
            source:
              name: Docker
        """

        #expect(throws: CommandActionRuleParseError.self) {
            _ = try parser.parse(yaml: yaml)
        }
    }

    @Test("Rejects unknown safety value")
    func rejectsUnknownSafety() throws {
        let yaml = """
        rules:
          - id: bad
            name: Bad rule
            tool: pnpm
            arguments: [store, prune]
            safety: maybe
            confidence: 50
            explanation: bogus
            category: developer_tool_command
            source: { name: pnpm }
        """

        #expect(throws: CommandActionRuleParseError.self) {
            _ = try parser.parse(yaml: yaml)
        }
    }

    @Test("Rejects negative or zero timeout_seconds")
    func rejectsNonPositiveTimeout() throws {
        let yaml = """
        rules:
          - id: bad
            name: Bad rule
            tool: pnpm
            arguments: [store, prune]
            safety: safe
            confidence: 90
            explanation: timeout must be positive
            category: developer_tool_command
            preconditions:
              timeout_seconds: 0
            source: { name: pnpm }
        """

        #expect(throws: CommandActionRuleParseError.self) {
            _ = try parser.parse(yaml: yaml)
        }
    }

    // MARK: - Required fields

    @Test("Reports the missing field for an incomplete rule")
    func reportsMissingField() throws {
        let yaml = """
        rules:
          - id: incomplete
            name: Incomplete rule
            tool: pnpm
            safety: safe
            confidence: 90
            explanation: missing arguments
            category: developer_tool_command
            source: { name: pnpm }
        """

        do {
            _ = try parser.parse(yaml: yaml)
            Issue.record("expected parser to throw")
        } catch let error as CommandActionRuleParseError {
            switch error {
            case .missingField(let field, _, _):
                #expect(field == "arguments")
            default:
                Issue.record("expected missingField, got \(error)")
            }
        }
    }

    @Test("Top-level YAML must contain a rules key")
    func rejectsMissingRulesKey() throws {
        let yaml = """
        cleanup:
          - id: x
        """

        #expect(throws: CommandActionRuleParseError.self) {
            _ = try parser.parse(yaml: yaml)
        }
    }
}
