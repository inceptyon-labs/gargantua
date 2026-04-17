import Foundation

/// Loads remnant rules from a directory of YAML rule files.
///
/// Mirrors `RuleLoader`'s API shape so callers can treat cleanup rules and
/// remnant rules with the same mental model. The loader walks the given
/// directory recursively, parses every `*.yaml` / `*.yml` file via
/// `RemnantRuleParser`, collects non-fatal errors, and continues on failure.
public struct RemnantRuleLoader: Sendable {
    private let parser = RemnantRuleParser()

    public init() {}

    /// Load all remnant rules from YAML files in the given directory (recursively).
    ///
    /// - Parameter directory: Root directory containing YAML remnant-rule files
    ///   (e.g., `Resources/uninstall_rules/`).
    /// - Returns: All parsed rules across all files, and any errors encountered.
    public func loadRules(from directory: URL) throws -> RemnantRuleLoadResult {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return RemnantRuleLoadResult(rules: [], errors: [], filesLoaded: 0)
        }

        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var allRules: [RemnantRule] = []
        var errors: [RemnantRuleParseError] = []
        var filesLoaded = 0

        while let url = enumerator?.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            guard ext == "yaml" || ext == "yml" else { continue }

            do {
                let yaml = try String(contentsOf: url, encoding: .utf8)
                let ruleFile = try parser.parse(yaml: yaml, filePath: url.path)
                allRules.append(contentsOf: ruleFile.rules)
                filesLoaded += 1
            } catch let error as RemnantRuleParseError {
                errors.append(error)
            } catch {
                errors.append(.invalidYAML(filePath: url.path, underlying: error))
            }
        }

        return RemnantRuleLoadResult(rules: allRules, errors: errors, filesLoaded: filesLoaded)
    }
}

/// The result of loading remnant rules from a directory.
public struct RemnantRuleLoadResult: Sendable {
    /// All successfully parsed remnant rules.
    public let rules: [RemnantRule]

    /// Errors encountered during parsing (non-fatal — other files still loaded).
    public let errors: [RemnantRuleParseError]

    /// Number of YAML files successfully loaded.
    public let filesLoaded: Int

    /// Whether all files loaded without errors.
    public var isClean: Bool { errors.isEmpty }
}
