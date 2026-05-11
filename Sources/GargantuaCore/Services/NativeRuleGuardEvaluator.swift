import Foundation

enum NativeRuleGuardEvaluator {
    static func shouldSkipRule(
        rule: ScanRule,
        processChecker: any RunningProcessChecking
    ) -> Bool {
        rule.skipIfProcessRunning.contains { processChecker.isRunning(identifier: $0) }
    }

    static func matchesRuleFilters(
        rule: ScanRule,
        lastAccessed: Date?,
        modifiedAt: Date?
    ) -> Bool {
        let evaluator = ConditionEvaluator()
        return rule.matchFilters.allSatisfy {
            evaluator.evaluate(condition: $0, lastAccessed: lastAccessed, modifiedAt: modifiedAt)
        }
    }

    static func isGuardedCandidate(rule: ScanRule, candidatePath: String) -> Bool {
        let fileManager = FileManager.default

        for guardRule in rule.presenceGuards {
            let path = resolveGuardPath(guardRule.path, scope: guardRule.scope, candidatePath: candidatePath)
            if fileManager.fileExists(atPath: path) {
                return true
            }
        }

        for guardRule in rule.contentGuards {
            let path = resolveGuardPath(guardRule.path, scope: guardRule.scope, candidatePath: candidatePath)
            guard fileManager.fileExists(atPath: path),
                  let contents = readGuardFile(atPath: path) else {
                continue
            }
            if guardRule.contains.contains(where: contents.contains) {
                return true
            }
        }

        return false
    }

    private static func resolveGuardPath(
        _ path: String,
        scope: RuleGuardPathScope,
        candidatePath: String
    ) -> String {
        if scope == .absolute || path.hasPrefix("/") || path.hasPrefix("~") {
            return expandTilde(path)
        }
        if path.isEmpty {
            return candidatePath
        }
        return (candidatePath as NSString).appendingPathComponent(path)
    }

    private static func readGuardFile(atPath path: String, byteLimit: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: byteLimit)
        return String(data: data, encoding: .utf8)
    }

    private static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return (path as NSString).expandingTildeInPath
    }
}
