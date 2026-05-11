import Foundation

extension RuleViewerView {
    func renderYAML(_ rule: ScanRule) -> String {
        var lines: [String] = [
            "- id: \(rule.id)",
            "  name: \(rule.name)",
        ]
        lines.append(contentsOf: Self.yamlPathBlock(rule))
        lines.append(contentsOf: Self.yamlMetadataBlock(rule))
        lines.append(contentsOf: Self.yamlSourceBlock(rule))
        lines.append(contentsOf: Self.yamlAuxiliaryBlock(rule))
        lines.append(contentsOf: Self.yamlOverridesBlock(rule))
        return lines.joined(separator: "\n")
    }

    private static func yamlPathBlock(_ rule: ScanRule) -> [String] {
        var lines: [String] = ["  paths:"]
        for path in rule.paths {
            lines.append("    - \"\(path)\"")
        }
        if let pattern = rule.pattern {
            lines.append("  pattern: \"\(pattern)\"")
        }
        if !rule.exclude.isEmpty {
            lines.append("  exclude:")
            for ex in rule.exclude {
                lines.append("    - \"\(ex)\"")
            }
        }
        return lines
    }

    private static func yamlMetadataBlock(_ rule: ScanRule) -> [String] {
        [
            "  safety: \(rule.safety.rawValue)",
            "  confidence: \(rule.confidence)",
            "  explanation: \"\(rule.explanation)\"",
        ]
    }

    private static func yamlSourceBlock(_ rule: ScanRule) -> [String] {
        var lines: [String] = [
            "  source:",
            "    name: \(rule.source.name)",
        ]
        if let bundleID = rule.source.bundleID {
            lines.append("    bundle_id: \(bundleID)")
        }
        lines.append("    verify_signature: \(rule.source.verifySignature)")
        return lines
    }

    private static func yamlAuxiliaryBlock(_ rule: ScanRule) -> [String] {
        var lines: [String] = ["  regenerates: \(rule.regenerates)"]
        if let cmd = rule.regenerateCommand {
            lines.append("  regenerateCommand: \"\(cmd)\"")
        }
        lines.append("  category: \(rule.category)")
        if !rule.tags.isEmpty {
            lines.append("  tags:")
            for tag in rule.tags {
                lines.append("    - \(tag)")
            }
        }
        return lines
    }

    private static func yamlOverridesBlock(_ rule: ScanRule) -> [String] {
        guard !rule.safetyOverrides.isEmpty else { return [] }
        var lines: [String] = ["  safety_overrides:"]
        for override_ in rule.safetyOverrides {
            lines.append("    - condition: \"\(override_.condition)\"")
            lines.append("      safety: \(override_.safety.rawValue)")
            if let confidence = override_.confidence {
                lines.append("      confidence: \(confidence)")
            }
            if let suffix = override_.explanationSuffix {
                lines.append("      explanation_suffix: \"\(suffix)\"")
            }
            if !override_.profiles.isEmpty {
                lines.append("      profiles:")
                for profile in override_.profiles {
                    lines.append("        - \(profile)")
                }
            }
        }
        return lines
    }
}
