import Foundation
import Yams

/// Errors that occur when parsing YAML rule files.
public enum RuleParseError: Error, CustomStringConvertible {
    /// The YAML could not be parsed at all.
    case invalidYAML(filePath: String, underlying: Error)

    /// A required field is missing from a rule definition.
    case missingField(field: String, ruleIndex: Int, filePath: String)

    /// A field has an invalid value.
    case invalidValue(field: String, value: String, expected: String, ruleIndex: Int, filePath: String)

    /// The top-level structure is not a mapping with a "rules" key.
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

/// Parses YAML rule files into typed `RuleFile` / `ScanRule` objects.
public struct RuleParser: Sendable {

    public init() {}

    /// Parse a YAML string into a `RuleFile`.
    ///
    /// - Parameters:
    ///   - yaml: The YAML content to parse.
    ///   - filePath: The file path for error reporting (does not need to exist on disk).
    /// - Returns: A `RuleFile` containing all parsed rules.
    /// - Throws: `RuleParseError` if the YAML is invalid or required fields are missing.
    public func parse(yaml: String, filePath: String = "<string>") throws -> RuleFile {
        let node: Node
        do {
            guard let parsed = try Yams.compose(yaml: yaml) else {
                throw RuleParseError.missingRulesKey(filePath: filePath)
            }
            node = parsed
        } catch let error as RuleParseError {
            throw error
        } catch {
            throw RuleParseError.invalidYAML(filePath: filePath, underlying: error)
        }

        guard let mapping = node.mapping,
              let rulesNode = mapping["rules"],
              let rulesSequence = rulesNode.sequence else {
            throw RuleParseError.missingRulesKey(filePath: filePath)
        }

        var rules: [ScanRule] = []
        for (index, ruleNode) in rulesSequence.enumerated() {
            let rule = try parseRule(from: ruleNode, index: index, filePath: filePath)
            rules.append(rule)
        }

        return RuleFile(rules: rules)
    }

    // MARK: - Private

    private func parseRule(from node: Node, index: Int, filePath: String) throws -> ScanRule {
        guard let mapping = node.mapping else {
            throw RuleParseError.missingField(field: "id", ruleIndex: index, filePath: filePath)
        }

        let id = try requireString("id", from: mapping, index: index, filePath: filePath)
        let name = try requireString("name", from: mapping, index: index, filePath: filePath)
        let paths = try requireStringArray("paths", from: mapping, index: index, filePath: filePath)
        let safetyStr = try requireString("safety", from: mapping, index: index, filePath: filePath)
        let confidence = try requireInt("confidence", from: mapping, index: index, filePath: filePath)
        let explanation = try requireString("explanation", from: mapping, index: index, filePath: filePath)
        let category = try requireString("category", from: mapping, index: index, filePath: filePath)

        guard let safety = SafetyLevel(rawValue: safetyStr) else {
            throw RuleParseError.invalidValue(
                field: "safety", value: safetyStr,
                expected: "safe|review|protected", ruleIndex: index, filePath: filePath
            )
        }

        let source = try parseSource(from: mapping, index: index, filePath: filePath)

        let pattern = optionalString("pattern", from: mapping)
        let exclude = optionalStringArray("exclude", from: mapping)
        let skipIfProcessRunning = optionalStringArray("skip_if_process_running", from: mapping)
        let presenceGuards = try parsePresenceGuards(from: mapping, index: index, filePath: filePath)
        let contentGuards = try parseContentGuards(from: mapping, index: index, filePath: filePath)
        let matchFilters = optionalStringArray("match_filters", from: mapping)
        let tags = optionalStringArray("tags", from: mapping)
        let regenerates = optionalBool("regenerates", from: mapping) ?? false
        let regenerateCommand = optionalString("regenerate_command", from: mapping)
        let safetyOverrides = try parseSafetyOverrides(from: mapping, index: index, filePath: filePath)

        return ScanRule(
            id: id,
            name: name,
            paths: paths,
            pattern: pattern,
            exclude: exclude,
            skipIfProcessRunning: skipIfProcessRunning,
            presenceGuards: presenceGuards,
            contentGuards: contentGuards,
            matchFilters: matchFilters,
            safety: safety,
            confidence: confidence,
            explanation: explanation,
            source: source,
            regenerates: regenerates,
            regenerateCommand: regenerateCommand,
            category: category,
            tags: tags,
            safetyOverrides: safetyOverrides
        )
    }

    private func parsePresenceGuards(
        from mapping: Node.Mapping,
        index: Int,
        filePath: String
    ) throws -> [RulePresenceGuard] {
        guard let guardsNode = mapping["presence_guards"],
              let guardsSequence = guardsNode.sequence else {
            return []
        }

        return try guardsSequence.enumerated().map { guardIndex, guardNode in
            guard let guardMapping = guardNode.mapping else {
                throw RuleParseError.missingField(
                    field: "presence_guards[\(guardIndex)].path",
                    ruleIndex: index,
                    filePath: filePath
                )
            }

            let path = try requireString("path", from: guardMapping, index: index, filePath: filePath)
            let scope = try parseGuardScope(
                optionalString("scope", from: guardMapping),
                field: "presence_guards[\(guardIndex)].scope",
                index: index,
                filePath: filePath
            )
            return RulePresenceGuard(path: path, scope: scope)
        }
    }

    private func parseContentGuards(
        from mapping: Node.Mapping,
        index: Int,
        filePath: String
    ) throws -> [RuleContentGuard] {
        guard let guardsNode = mapping["content_guards"],
              let guardsSequence = guardsNode.sequence else {
            return []
        }

        return try guardsSequence.enumerated().map { guardIndex, guardNode in
            guard let guardMapping = guardNode.mapping else {
                throw RuleParseError.missingField(
                    field: "content_guards[\(guardIndex)].path",
                    ruleIndex: index,
                    filePath: filePath
                )
            }

            let path = try requireString("path", from: guardMapping, index: index, filePath: filePath)
            let contains = try requireStringOrStringArray(
                "contains",
                from: guardMapping,
                index: index,
                filePath: filePath
            )
            let scope = try parseGuardScope(
                optionalString("scope", from: guardMapping),
                field: "content_guards[\(guardIndex)].scope",
                index: index,
                filePath: filePath
            )
            return RuleContentGuard(path: path, contains: contains, scope: scope)
        }
    }

    private func parseGuardScope(
        _ raw: String?,
        field: String,
        index: Int,
        filePath: String
    ) throws -> RuleGuardPathScope {
        guard let raw else { return .candidate }
        guard let scope = RuleGuardPathScope(rawValue: raw) else {
            throw RuleParseError.invalidValue(
                field: field,
                value: raw,
                expected: "candidate|absolute",
                ruleIndex: index,
                filePath: filePath
            )
        }
        return scope
    }

    private func parseSource(from mapping: Node.Mapping, index: Int, filePath: String) throws -> SourceAttribution {
        guard let sourceNode = mapping["source"], let sourceMapping = sourceNode.mapping else {
            throw RuleParseError.missingField(field: "source", ruleIndex: index, filePath: filePath)
        }

        let name = try requireString("name", from: sourceMapping, index: index, filePath: filePath)
        let bundleID = optionalString("bundle_id", from: sourceMapping)
        let verifySignature = optionalBool("verify_signature", from: sourceMapping) ?? false

        return SourceAttribution(name: name, bundleID: bundleID, verifySignature: verifySignature)
    }

    private func parseSafetyOverrides(from mapping: Node.Mapping, index: Int, filePath: String) throws -> [SafetyOverride] {
        guard let overridesNode = mapping["safety_overrides"],
              let overridesSequence = overridesNode.sequence else {
            return []
        }

        return try overridesSequence.enumerated().map { (overrideIndex, overrideNode) in
            guard let overrideMapping = overrideNode.mapping else {
                throw RuleParseError.missingField(
                    field: "safety_overrides[\(overrideIndex)]",
                    ruleIndex: index, filePath: filePath
                )
            }

            let condition = try requireString("condition", from: overrideMapping, index: index, filePath: filePath)
            let safetyStr = try requireString("safety", from: overrideMapping, index: index, filePath: filePath)

            guard let safety = SafetyLevel(rawValue: safetyStr) else {
                throw RuleParseError.invalidValue(
                    field: "safety_overrides[\(overrideIndex)].safety", value: safetyStr,
                    expected: "safe|review|protected", ruleIndex: index, filePath: filePath
                )
            }

            let confidence = optionalInt("confidence", from: overrideMapping)
            let explanationSuffix = optionalString("explanation_suffix", from: overrideMapping)
            let profiles = optionalStringArray("profiles", from: overrideMapping)

            return SafetyOverride(
                condition: condition,
                safety: safety,
                confidence: confidence,
                explanationSuffix: explanationSuffix,
                profiles: profiles
            )
        }
    }

    // MARK: - Node Helpers

    private func requireString(_ key: String, from mapping: Node.Mapping, index: Int, filePath: String) throws -> String {
        guard let node = mapping[key], let value = node.string else {
            throw RuleParseError.missingField(field: key, ruleIndex: index, filePath: filePath)
        }
        return value
    }

    private func requireInt(_ key: String, from mapping: Node.Mapping, index: Int, filePath: String) throws -> Int {
        guard let node = mapping[key], let value = node.int else {
            throw RuleParseError.missingField(field: key, ruleIndex: index, filePath: filePath)
        }
        return value
    }

    private func requireStringArray(_ key: String, from mapping: Node.Mapping, index: Int, filePath: String) throws -> [String] {
        guard let node = mapping[key], let sequence = node.sequence else {
            throw RuleParseError.missingField(field: key, ruleIndex: index, filePath: filePath)
        }
        return sequence.compactMap { $0.string }
    }

    private func requireStringOrStringArray(
        _ key: String,
        from mapping: Node.Mapping,
        index: Int,
        filePath: String
    ) throws -> [String] {
        guard let node = mapping[key] else {
            throw RuleParseError.missingField(field: key, ruleIndex: index, filePath: filePath)
        }
        if let string = node.string {
            return [string]
        }
        if let sequence = node.sequence {
            return sequence.compactMap { $0.string }
        }
        throw RuleParseError.missingField(field: key, ruleIndex: index, filePath: filePath)
    }

    private func optionalString(_ key: String, from mapping: Node.Mapping) -> String? {
        mapping[key]?.string
    }

    private func optionalInt(_ key: String, from mapping: Node.Mapping) -> Int? {
        mapping[key]?.int
    }

    private func optionalBool(_ key: String, from mapping: Node.Mapping) -> Bool? {
        mapping[key]?.bool
    }

    private func optionalStringArray(_ key: String, from mapping: Node.Mapping) -> [String] {
        guard let node = mapping[key], let sequence = node.sequence else { return [] }
        return sequence.compactMap { $0.string }
    }
}

// MARK: - Node Key Access

private extension Node.Mapping {
    subscript(key: String) -> Node? {
        self[Node(key)]
    }
}
