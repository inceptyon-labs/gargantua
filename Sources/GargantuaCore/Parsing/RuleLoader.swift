import Foundation

/// Loads scan rules from a directory of YAML rule files.
public struct RuleLoader: Sendable {
    private let parser = RuleParser()

    public init() {}

    /// Load all rules from YAML files in the given directory (recursively).
    ///
    /// - Parameter directory: The root directory containing YAML rule files (e.g., `cleanup_rules/`).
    /// - Returns: All parsed rules across all files, and any errors encountered.
    public func loadRules(from directory: URL) throws -> RuleLoadResult {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return RuleLoadResult(rules: [], errors: [], filesLoaded: 0)
        }

        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var allRules: [ScanRule] = []
        var errors: [RuleParseError] = []
        var filesLoaded = 0

        while let url = enumerator?.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            guard ext == "yaml" || ext == "yml" else { continue }

            do {
                let yaml = try String(contentsOf: url, encoding: .utf8)
                let ruleFile = try parser.parse(yaml: yaml, filePath: url.path)
                allRules.append(contentsOf: ruleFile.rules)
                filesLoaded += 1
            } catch let error as RuleParseError {
                errors.append(error)
            } catch {
                errors.append(.invalidYAML(filePath: url.path, underlying: error))
            }
        }

        return RuleLoadResult(rules: allRules, errors: errors, filesLoaded: filesLoaded)
    }
}

/// The result of loading rules from a directory.
public struct RuleLoadResult: Sendable {
    /// All successfully parsed rules.
    public let rules: [ScanRule]

    /// Errors encountered during parsing (non-fatal — other files still loaded).
    public let errors: [RuleParseError]

    /// Number of YAML files successfully loaded.
    public let filesLoaded: Int

    /// Whether all files loaded without errors.
    public var isClean: Bool { errors.isEmpty }
}
