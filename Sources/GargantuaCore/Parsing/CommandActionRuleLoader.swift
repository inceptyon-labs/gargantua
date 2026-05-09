import Foundation

/// Loads command-action rules from a directory of YAML rule files.
///
/// Mirrors `RuleLoader`'s contract: walks the directory recursively, parses
/// each `.yaml` / `.yml` file, and aggregates results plus per-file errors.
public struct CommandActionRuleLoader: Sendable {
    private let parser = CommandActionRuleParser()
    private let protectedRootPolicy: ProtectedRootPolicy

    public init(protectedRootPolicy: ProtectedRootPolicy = .loadDefault()) {
        self.protectedRootPolicy = protectedRootPolicy
    }

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
                let validationErrors = validate(ruleFile.rules, filePath: url.path)
                if !validationErrors.isEmpty {
                    errors.append(contentsOf: validationErrors)
                    continue
                }
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

    private func validate(_ rules: [CommandActionRule], filePath: String) -> [CommandActionRuleParseError] {
        var errors: [CommandActionRuleParseError] = []
        for (index, rule) in rules.enumerated() {
            errors.append(contentsOf: validate(rule, index: index, filePath: filePath))
        }
        return errors
    }

    private func validate(
        _ rule: CommandActionRule,
        index: Int,
        filePath: String
    ) -> [CommandActionRuleParseError] {
        var errors: [CommandActionRuleParseError] = []
        if rule.affectedRoots.isEmpty {
            errors.append(.missingField(field: "affected_roots", ruleIndex: index, filePath: filePath))
        }
        for root in rule.affectedRoots {
            let url = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
            if let reason = protectedRootPolicy.protectionReason(for: url) {
                errors.append(.invalidValue(
                    field: "affected_roots",
                    value: root,
                    expected: "non-protected cleanup root (\(reason))",
                    ruleIndex: index,
                    filePath: filePath
                ))
            }
        }
        if rule.category == CommandActionRuleCategory.advanced {
            if rule.safety != .review {
                errors.append(.invalidValue(
                    field: "safety",
                    value: rule.safety.rawValue,
                    expected: "review for advanced command-action rules",
                    ruleIndex: index,
                    filePath: filePath
                ))
            }
            if rule.consequence?.isEmpty != false {
                errors.append(.missingField(field: "consequence", ruleIndex: index, filePath: filePath))
            }
            if rule.regenerateCommand?.isEmpty != false {
                errors.append(.missingField(field: "regenerate_command", ruleIndex: index, filePath: filePath))
            }
        }
        return errors
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
