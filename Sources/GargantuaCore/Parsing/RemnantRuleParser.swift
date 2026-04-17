import Foundation
import Yams

/// Errors raised while parsing YAML remnant-rule files.
public enum RemnantRuleParseError: Error, CustomStringConvertible {
    case invalidYAML(filePath: String, underlying: Error)
    case missingRulesKey(filePath: String)
    case missingField(field: String, ruleIndex: Int, filePath: String)
    case invalidValue(field: String, value: String, expected: String, ruleIndex: Int, filePath: String)

    public var description: String {
        switch self {
        case .invalidYAML(let filePath, let underlying):
            return "\(filePath): invalid YAML — \(underlying.localizedDescription)"
        case .missingRulesKey(let filePath):
            return "\(filePath): missing top-level 'remnant_rules' key"
        case .missingField(let field, let ruleIndex, let filePath):
            return "\(filePath): remnant_rules[\(ruleIndex)] missing required field '\(field)'"
        case .invalidValue(let field, let value, let expected, let ruleIndex, let filePath):
            return "\(filePath): remnant_rules[\(ruleIndex)] field '\(field)' has invalid value '\(value)' (expected \(expected))"
        }
    }
}

/// Parses YAML remnant-rule files into typed `RemnantRuleFile` objects.
///
/// The YAML schema is intentionally close to the `RuleParser` schema so
/// authors can move between the two without re-learning field names.
/// Top-level key is `remnant_rules` (not `rules`) so loaders can tell
/// the two file kinds apart in a single directory tree.
public struct RemnantRuleParser: Sendable {

    public init() {}

    public func parse(yaml: String, filePath: String = "<string>") throws -> RemnantRuleFile {
        let node: Node
        do {
            guard let parsed = try Yams.compose(yaml: yaml) else {
                throw RemnantRuleParseError.missingRulesKey(filePath: filePath)
            }
            node = parsed
        } catch let error as RemnantRuleParseError {
            throw error
        } catch {
            throw RemnantRuleParseError.invalidYAML(filePath: filePath, underlying: error)
        }

        guard let mapping = node.mapping,
              let rulesNode = mapping["remnant_rules"],
              let rulesSequence = rulesNode.sequence else {
            throw RemnantRuleParseError.missingRulesKey(filePath: filePath)
        }

        var rules: [RemnantRule] = []
        for (index, ruleNode) in rulesSequence.enumerated() {
            rules.append(try parseRule(from: ruleNode, index: index, filePath: filePath))
        }
        return RemnantRuleFile(rules: rules)
    }

    // MARK: - Rule

    private func parseRule(from node: Node, index: Int, filePath: String) throws -> RemnantRule {
        guard let mapping = node.mapping else {
            throw RemnantRuleParseError.missingField(field: "id", ruleIndex: index, filePath: filePath)
        }

        let id = try requireString("id", from: mapping, index: index, filePath: filePath)
        let name = try requireString("name", from: mapping, index: index, filePath: filePath)
        let categoryStr = try requireString("category", from: mapping, index: index, filePath: filePath)
        let pathTemplates = try requireStringArray("path_templates", from: mapping, index: index, filePath: filePath)
        let confidence = try requireInt("confidence", from: mapping, index: index, filePath: filePath)
        let explanation = try requireString("explanation", from: mapping, index: index, filePath: filePath)

        guard let category = RemnantCategory(rawValue: categoryStr) else {
            throw RemnantRuleParseError.invalidValue(
                field: "category", value: categoryStr,
                expected: RemnantCategory.allCases.map(\.rawValue).joined(separator: "|"),
                ruleIndex: index, filePath: filePath
            )
        }

        let safety: SafetyLevel
        if let safetyStr = optionalString("safety", from: mapping) {
            guard let parsed = SafetyLevel(rawValue: safetyStr) else {
                throw RemnantRuleParseError.invalidValue(
                    field: "safety", value: safetyStr,
                    expected: "safe|review|protected", ruleIndex: index, filePath: filePath
                )
            }
            safety = parsed
        } else {
            safety = category.defaultSafety
        }

        let source = try parseSource(from: mapping, index: index, filePath: filePath)
        let appliesTo = parseAppScope(from: mapping)

        return RemnantRule(
            id: id,
            name: name,
            category: category,
            pathTemplates: pathTemplates,
            pattern: optionalString("pattern", from: mapping),
            exclude: optionalStringArray("exclude", from: mapping),
            safety: safety,
            confidence: confidence,
            explanation: explanation,
            source: source,
            appliesTo: appliesTo,
            regenerates: optionalBool("regenerates", from: mapping) ?? false,
            tags: optionalStringArray("tags", from: mapping)
        )
    }

    private func parseSource(from mapping: Node.Mapping, index: Int, filePath: String) throws -> SourceAttribution {
        guard let sourceNode = mapping["source"], let sourceMapping = sourceNode.mapping else {
            throw RemnantRuleParseError.missingField(field: "source", ruleIndex: index, filePath: filePath)
        }
        let name = try requireString("name", from: sourceMapping, index: index, filePath: filePath)
        let bundleID = optionalString("bundle_id", from: sourceMapping)
        let verifySignature = optionalBool("verify_signature", from: sourceMapping) ?? false
        return SourceAttribution(name: name, bundleID: bundleID, verifySignature: verifySignature)
    }

    private func parseAppScope(from mapping: Node.Mapping) -> AppScope? {
        guard let scopeNode = mapping["applies_to"], let scopeMapping = scopeNode.mapping else {
            return nil
        }
        let bundleIDs = optionalStringArray("bundle_ids", from: scopeMapping)
        let excludeBundleIDs = optionalStringArray("exclude_bundle_ids", from: scopeMapping)
        if bundleIDs.isEmpty && excludeBundleIDs.isEmpty { return nil }
        return AppScope(bundleIDs: bundleIDs, excludeBundleIDs: excludeBundleIDs)
    }

    // MARK: - Node Helpers

    private func requireString(_ key: String, from mapping: Node.Mapping, index: Int, filePath: String) throws -> String {
        guard let node = mapping[key], let value = node.string else {
            throw RemnantRuleParseError.missingField(field: key, ruleIndex: index, filePath: filePath)
        }
        return value
    }

    private func requireInt(_ key: String, from mapping: Node.Mapping, index: Int, filePath: String) throws -> Int {
        guard let node = mapping[key], let value = node.int else {
            throw RemnantRuleParseError.missingField(field: key, ruleIndex: index, filePath: filePath)
        }
        return value
    }

    private func requireStringArray(_ key: String, from mapping: Node.Mapping, index: Int, filePath: String) throws -> [String] {
        guard let node = mapping[key], let sequence = node.sequence else {
            throw RemnantRuleParseError.missingField(field: key, ruleIndex: index, filePath: filePath)
        }
        return sequence.compactMap(\.string)
    }

    private func optionalString(_ key: String, from mapping: Node.Mapping) -> String? {
        mapping[key]?.string
    }

    private func optionalBool(_ key: String, from mapping: Node.Mapping) -> Bool? {
        mapping[key]?.bool
    }

    private func optionalStringArray(_ key: String, from mapping: Node.Mapping) -> [String] {
        guard let node = mapping[key], let sequence = node.sequence else { return [] }
        return sequence.compactMap(\.string)
    }
}

private extension Node.Mapping {
    subscript(key: String) -> Node? {
        self[Node(key)]
    }
}
