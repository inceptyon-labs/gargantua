// File intentionally large: covers the full YAML schema for cleanup rules
// in one place so a reader can find any field without bouncing across files.
// swiftlint:disable file_length

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

// Parses YAML rule files into typed `RuleFile` / `ScanRule` objects.
// Type body covers the full set of field-level YAML decoders so the rule
// schema is auditable from a single struct.
// swiftlint:disable:next type_body_length
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
        let minSize = try parseMinSize(from: mapping, index: index, filePath: filePath)
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
            minSize: minSize,
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

    /// Parse a `min_size` field as either a raw byte count or a human-readable
    /// suffix string (e.g. `100MB`, `1.5 GB`, `512 KiB`).
    private func parseMinSize(from mapping: Node.Mapping, index: Int, filePath: String) throws -> Int64? {
        guard let node = mapping["min_size"] else { return nil }

        if let intValue = node.int {
            return Int64(intValue)
        }

        guard let stringValue = node.string else {
            throw RuleParseError.invalidValue(
                field: "min_size",
                value: "<non-string, non-int>",
                expected: "integer bytes or string with unit suffix (e.g. '100MB')",
                ruleIndex: index,
                filePath: filePath
            )
        }

        if let parsed = SizeStringParser.parse(stringValue) {
            return parsed
        }

        throw RuleParseError.invalidValue(
            field: "min_size",
            value: stringValue,
            expected: "integer bytes or string with unit suffix (e.g. '100MB', '1.5GB')",
            ruleIndex: index,
            filePath: filePath
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

// MARK: - Size string parsing

/// Parses byte-count strings like "100MB", "1.5 GiB", "512KB" into Int64 bytes.
///
/// Bare suffixes (`MB`) and IEC suffixes (`MiB`) both use 1024^n to match how
/// macOS Finder typically displays sizes. Returns `nil` for nonsense input,
/// negative values, NaN/infinity, or values that overflow `Int64`.
enum SizeStringParser {
    /// Multipliers for known byte-count unit suffixes (uppercased).
    private static let multipliers: [String: Int64] = [
        "": 1, "B": 1,
        "K": 1024, "KB": 1024, "KIB": 1024,
        "M": 1024 * 1024, "MB": 1024 * 1024, "MIB": 1024 * 1024,
        "G": 1024 * 1024 * 1024, "GB": 1024 * 1024 * 1024, "GIB": 1024 * 1024 * 1024,
        "T": 1024 * 1024 * 1024 * 1024, "TB": 1024 * 1024 * 1024 * 1024, "TIB": 1024 * 1024 * 1024 * 1024,
    ]

    static func parse(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let (numericPart, unitPart) = splitNumericAndUnit(trimmed)
        guard let multiplier = multipliers[unitPart] else { return nil }

        // Whole-number numerics go through Int64 directly to preserve precision
        // near `Int64.max` — `Double` rounds at 2^53 and silently maps
        // `Int64.max + 1` to the same Double as `Int64.max`.
        if !numericPart.contains(".") {
            guard let value = Int64(numericPart), value >= 0 else { return nil }
            return value.multipliedReportingOverflow(by: multiplier).overflow ? nil
                : value * multiplier
        }

        guard let value = Double(numericPart), value.isFinite, value >= 0 else { return nil }
        let scaled = value * Double(multiplier)
        guard scaled.isFinite, scaled >= 0,
              scaled < Double(Int64.max) - 1 else { // -1 keeps us clear of the rounded boundary
            return nil
        }
        return Int64(scaled)
    }

    private static func splitNumericAndUnit(_ raw: String) -> (numeric: String, unit: String) {
        let numericChars = CharacterSet(charactersIn: "0123456789.")
        var splitIndex = raw.endIndex
        for index in raw.indices {
            guard let scalar = raw[index].unicodeScalars.first else { continue }
            if !numericChars.contains(scalar) {
                splitIndex = index
                break
            }
        }
        let numericPart = String(raw[..<splitIndex])
        let unitPart = raw[splitIndex...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return (numericPart, unitPart)
    }
}
