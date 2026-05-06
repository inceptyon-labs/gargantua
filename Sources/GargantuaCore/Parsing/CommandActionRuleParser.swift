import Foundation
import Yams

/// Errors that occur when parsing a YAML command-action rule file.
public enum CommandActionRuleParseError: Error, CustomStringConvertible {
    case invalidYAML(filePath: String, underlying: Error)
    case missingField(field: String, ruleIndex: Int, filePath: String)
    case invalidValue(field: String, value: String, expected: String, ruleIndex: Int, filePath: String)
    case missingRulesKey(filePath: String)

    public var description: String {
        switch self {
        case .invalidYAML(let filePath, let underlying):
            return "\(filePath): invalid YAML — \(underlying.localizedDescription)"
        case .missingField(let field, let ruleIndex, let filePath):
            return "\(filePath): rule[\(ruleIndex)] missing required field '\(field)'"
        case .invalidValue(let field, let value, let expected, let ruleIndex, let filePath):
            return "\(filePath): rule[\(ruleIndex)] field '\(field)' has invalid value '\(value)' (expected \(expected))"
        case .missingRulesKey(let filePath):
            return "\(filePath): missing top-level 'rules' key"
        }
    }
}

/// Parses YAML command-action rule files into typed `CommandActionRuleFile`
/// objects. Mirrors `RuleParser`'s Yams Node-walker style so the schema is
/// auditable from a single struct.
public struct CommandActionRuleParser: Sendable {
    public init() {}

    public func parse(yaml: String, filePath: String = "<string>") throws -> CommandActionRuleFile {
        let node: Node
        do {
            guard let parsed = try Yams.compose(yaml: yaml) else {
                throw CommandActionRuleParseError.missingRulesKey(filePath: filePath)
            }
            node = parsed
        } catch let error as CommandActionRuleParseError {
            throw error
        } catch {
            throw CommandActionRuleParseError.invalidYAML(filePath: filePath, underlying: error)
        }

        guard let mapping = node.mapping,
              let rulesNode = mapping["rules"],
              let rulesSequence = rulesNode.sequence else {
            throw CommandActionRuleParseError.missingRulesKey(filePath: filePath)
        }

        var rules: [CommandActionRule] = []
        for (index, ruleNode) in rulesSequence.enumerated() {
            rules.append(try parseRule(from: ruleNode, index: index, filePath: filePath))
        }

        return CommandActionRuleFile(rules: rules)
    }

    // MARK: - Private

    private func parseRule(from node: Node, index: Int, filePath: String) throws -> CommandActionRule {
        guard let mapping = node.mapping else {
            throw CommandActionRuleParseError.missingField(field: "id", ruleIndex: index, filePath: filePath)
        }

        let id = try requireString("id", from: mapping, index: index, filePath: filePath)
        let name = try requireString("name", from: mapping, index: index, filePath: filePath)
        let tool = try requireString("tool", from: mapping, index: index, filePath: filePath)
        let arguments = try requireStringArray("arguments", from: mapping, index: index, filePath: filePath)
        let safetyStr = try requireString("safety", from: mapping, index: index, filePath: filePath)
        let confidence = try requireInt("confidence", from: mapping, index: index, filePath: filePath)
        let explanation = try requireString("explanation", from: mapping, index: index, filePath: filePath)
        let category = try requireString("category", from: mapping, index: index, filePath: filePath)

        guard let safety = SafetyLevel(rawValue: safetyStr) else {
            throw CommandActionRuleParseError.invalidValue(
                field: "safety",
                value: safetyStr,
                expected: "safe|review|protected",
                ruleIndex: index,
                filePath: filePath
            )
        }

        // Codex's Trust Layer note: `protected` makes no sense for a
        // command-action rule — the Trust Layer's hard-reject path operates
        // on filesystem entries, not tool invocations. Reject at parse time
        // so a bad YAML can never sneak past as "we'll just refuse to run it
        // later."
        if safety == .protected_ {
            throw CommandActionRuleParseError.invalidValue(
                field: "safety",
                value: safetyStr,
                expected: "safe|review (protected is not allowed for command-action rules)",
                ruleIndex: index,
                filePath: filePath
            )
        }

        let dryRunArguments = optionalStringArrayOrNil("dry_run_arguments", from: mapping)
        let regenerates = optionalBool("regenerates", from: mapping) ?? false
        let regenerateCommand = optionalString("regenerate_command", from: mapping)
        let affectedRoots = optionalStringArray("affected_roots", from: mapping)
        let preconditions = try parsePreconditions(from: mapping, index: index, filePath: filePath)
        let source = try parseSource(from: mapping, index: index, filePath: filePath)
        let tags = optionalStringArray("tags", from: mapping)

        return CommandActionRule(
            id: id,
            name: name,
            tool: tool,
            arguments: arguments,
            dryRunArguments: dryRunArguments,
            safety: safety,
            confidence: confidence,
            explanation: explanation,
            category: category,
            regenerates: regenerates,
            regenerateCommand: regenerateCommand,
            affectedRoots: affectedRoots,
            preconditions: preconditions,
            source: source,
            tags: tags
        )
    }

    private func parsePreconditions(
        from mapping: Node.Mapping,
        index: Int,
        filePath: String
    ) throws -> CommandActionPreconditions {
        guard let node = mapping["preconditions"], let preMapping = node.mapping else {
            return CommandActionPreconditions()
        }

        let timeoutSeconds: TimeInterval
        if let raw = preMapping["timeout_seconds"] {
            if let intValue = raw.int {
                timeoutSeconds = TimeInterval(intValue)
            } else if let stringValue = raw.string, let doubleValue = Double(stringValue) {
                timeoutSeconds = TimeInterval(doubleValue)
            } else {
                throw CommandActionRuleParseError.invalidValue(
                    field: "preconditions.timeout_seconds",
                    value: raw.string ?? "<non-numeric>",
                    expected: "positive number of seconds",
                    ruleIndex: index,
                    filePath: filePath
                )
            }
            if timeoutSeconds <= 0 {
                throw CommandActionRuleParseError.invalidValue(
                    field: "preconditions.timeout_seconds",
                    value: "\(timeoutSeconds)",
                    expected: "positive number of seconds",
                    ruleIndex: index,
                    filePath: filePath
                )
            }
        } else {
            timeoutSeconds = 60
        }

        return CommandActionPreconditions(timeoutSeconds: timeoutSeconds)
    }

    private func parseSource(
        from mapping: Node.Mapping,
        index: Int,
        filePath: String
    ) throws -> SourceAttribution {
        guard let sourceNode = mapping["source"], let sourceMapping = sourceNode.mapping else {
            throw CommandActionRuleParseError.missingField(field: "source", ruleIndex: index, filePath: filePath)
        }
        let name = try requireString("name", from: sourceMapping, index: index, filePath: filePath)
        let bundleID = optionalString("bundle_id", from: sourceMapping)
        let verifySignature = optionalBool("verify_signature", from: sourceMapping) ?? false
        return SourceAttribution(name: name, bundleID: bundleID, verifySignature: verifySignature)
    }

    // MARK: - Node helpers

    private func requireString(
        _ key: String,
        from mapping: Node.Mapping,
        index: Int,
        filePath: String
    ) throws -> String {
        guard let node = mapping[key], let value = node.string else {
            throw CommandActionRuleParseError.missingField(field: key, ruleIndex: index, filePath: filePath)
        }
        return value
    }

    private func requireInt(
        _ key: String,
        from mapping: Node.Mapping,
        index: Int,
        filePath: String
    ) throws -> Int {
        guard let node = mapping[key], let value = node.int else {
            throw CommandActionRuleParseError.missingField(field: key, ruleIndex: index, filePath: filePath)
        }
        return value
    }

    private func requireStringArray(
        _ key: String,
        from mapping: Node.Mapping,
        index: Int,
        filePath: String
    ) throws -> [String] {
        guard let node = mapping[key], let sequence = node.sequence else {
            throw CommandActionRuleParseError.missingField(field: key, ruleIndex: index, filePath: filePath)
        }
        return sequence.compactMap { $0.string }
    }

    private func optionalString(_ key: String, from mapping: Node.Mapping) -> String? {
        mapping[key]?.string
    }

    private func optionalBool(_ key: String, from mapping: Node.Mapping) -> Bool? {
        mapping[key]?.bool
    }

    private func optionalStringArray(_ key: String, from mapping: Node.Mapping) -> [String] {
        guard let node = mapping[key], let sequence = node.sequence else { return [] }
        return sequence.compactMap { $0.string }
    }

    /// Same as `optionalStringArray`, but returns `nil` when the key is absent
    /// so callers can distinguish "not specified" from "specified but empty."
    private func optionalStringArrayOrNil(_ key: String, from mapping: Node.Mapping) -> [String]? {
        guard let node = mapping[key], let sequence = node.sequence else { return nil }
        return sequence.compactMap { $0.string }
    }
}

private extension Node.Mapping {
    subscript(key: String) -> Node? {
        self[Node(key)]
    }
}
