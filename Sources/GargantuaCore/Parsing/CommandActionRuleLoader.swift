import Foundation

/// Loads command-action rules from a directory of YAML rule files.
///
/// Mirrors `RuleLoader`'s contract: walks the directory recursively, parses
/// each `.yaml` / `.yml` file, and aggregates results plus per-file errors.
public struct CommandActionRuleLoader: Sendable {
    private let parser = CommandActionRuleParser()

    public init() {}

    public func loadRules(from directory: URL) throws -> CommandActionRuleLoadResult {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return CommandActionRuleLoadResult(rules: [], errors: [], filesLoaded: 0)
        }

        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var allRules: [CommandActionRule] = []
        var errors: [CommandActionRuleParseError] = []
        var filesLoaded = 0

        while let url = enumerator?.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            guard ext == "yaml" || ext == "yml" else { continue }

            do {
                let yaml = try String(contentsOf: url, encoding: .utf8)
                let ruleFile = try parser.parse(yaml: yaml, filePath: url.path)
                allRules.append(contentsOf: ruleFile.rules)
                filesLoaded += 1
            } catch let error as CommandActionRuleParseError {
                errors.append(error)
            } catch {
                errors.append(.invalidYAML(filePath: url.path, underlying: error))
            }
        }

        return CommandActionRuleLoadResult(rules: allRules, errors: errors, filesLoaded: filesLoaded)
    }
}

public struct CommandActionRuleLoadResult: Sendable {
    public let rules: [CommandActionRule]
    public let errors: [CommandActionRuleParseError]
    public let filesLoaded: Int

    public var isClean: Bool { errors.isEmpty }
}

/// Resolves the directory containing YAML command-action rule files.
///
/// Search order mirrors `RuleDirectoryResolver`:
/// 1. `GARGANTUA_COMMAND_RULES_DIR` env override
/// 2. `Bundle.module.resourceURL/command_rules`
/// 3. `Bundle.main.resourceURL/command_rules`
public enum CommandActionRuleDirectoryResolver {
    public static func resolve() -> URL? {
        let fm = FileManager.default

        if let envPath = ProcessInfo.processInfo.environment["GARGANTUA_COMMAND_RULES_DIR"], !envPath.isEmpty {
            let url = URL(fileURLWithPath: envPath, isDirectory: true)
            if fm.fileExists(atPath: url.path) { return url }
        }

        if let resourceURL = Bundle.module.resourceURL {
            let candidate = resourceURL.appendingPathComponent("command_rules", isDirectory: true)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        if let mainResourceURL = Bundle.main.resourceURL {
            let candidate = mainResourceURL.appendingPathComponent("command_rules", isDirectory: true)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        return nil
    }
}
