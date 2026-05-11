import Foundation

extension RemnantScanner {
    struct RuleEvaluation {
        let items: [RemnantItem]
        let reservedPaths: [String]
    }

    fileprivate struct RuleContext {
        let rule: RemnantRule
        let app: AppInfo
        let excludes: [String]
    }

    func evaluate(
        rule: RemnantRule,
        app: AppInfo
    ) -> RuleEvaluation {
        var out: [RemnantItem] = []
        var reservedPaths: [String] = []
        var counter = 0

        let expandedExcludes = rule.exclude.flatMap { Self.expandAll(template: $0, for: app) }

        for template in rule.pathTemplates {
            let expandedTemplates = Self.expandAll(template: template, for: app)

            for expanded in expandedTemplates {
                let isGlob = expanded.contains("*")
                let paths: [String]
                if isGlob {
                    paths = expander.expand(pattern: expanded, roots: scanRoots).paths
                } else {
                    paths = Self.existingFilesystemPath(for: expanded).map { [$0] } ?? []
                }

                for path in paths {
                    reservedPaths.append(path)
                    let needsChildEnumeration = rule.pattern != nil || (!isGlob && !expandedExcludes.isEmpty)
                    if needsChildEnumeration {
                        enumerateChildren(
                            at: path,
                            context: RuleContext(rule: rule, app: app, excludes: expandedExcludes),
                            counter: &counter,
                            into: &out
                        )
                    } else {
                        let url = URL(fileURLWithPath: path)
                        if Self.isExcluded(url, excludes: expandedExcludes) {
                            observer?.didEmit(ScanProgressEvent(
                                path: path,
                                outcome: .skipped(reason: "exclude rule")
                            ))
                            continue
                        }
                        observer?.didEmit(ScanProgressEvent(path: path, outcome: .checked))
                        if let item = Self.makeItem(rule: rule, app: app, path: path, counter: &counter) {
                            out.append(item)
                        }
                    }
                }
            }
        }

        return RuleEvaluation(items: out, reservedPaths: reservedPaths)
    }

    fileprivate func enumerateChildren(
        at path: String,
        context: RuleContext,
        counter: inout Int,
        into out: inout [RemnantItem]
    ) {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for child in children {
            if let pattern = context.rule.pattern {
                let patterns = Self.expandAll(template: pattern, for: context.app)
                if !patterns.contains(where: { PathExpander.fnmatch(pattern: $0, name: child.lastPathComponent) }) {
                    observer?.didEmit(ScanProgressEvent(
                        path: child.path,
                        outcome: .skipped(reason: "pattern miss")
                    ))
                    continue
                }
            }
            if Self.isExcluded(child, excludes: context.excludes) {
                observer?.didEmit(ScanProgressEvent(
                    path: child.path,
                    outcome: .skipped(reason: "exclude rule")
                ))
                continue
            }
            observer?.didEmit(ScanProgressEvent(path: child.path, outcome: .checked))
            if let item = Self.makeItem(rule: context.rule, app: context.app, path: child.path, counter: &counter) {
                out.append(item)
            }
        }
    }

    static func rulePriority(_ rule: RemnantRule) -> Int {
        rule.tags.contains("app_pack") ? 0 : 1
    }

    fileprivate static func isExcluded(_ url: URL, excludes: [String]) -> Bool {
        let path = url.path
        let name = url.lastPathComponent
        for pattern in excludes {
            let expanded = (pattern as NSString).expandingTildeInPath
            var basenamePattern = expanded
            if basenamePattern.hasPrefix("*/") { basenamePattern.removeFirst(2) }
            let globPattern = expanded.replacingOccurrences(of: "**", with: "*")
            if PathExpander.fnmatch(pattern: basenamePattern, name: name)
                || PathExpander.fnmatch(pattern: globPattern, name: path) {
                return true
            }
        }
        return false
    }

    fileprivate static func existingFilesystemPath(for path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: expanded) else { return nil }

        let url = URL(fileURLWithPath: expanded)
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let parentPath = (expanded as NSString).deletingLastPathComponent
        guard let children = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        ) else {
            return expanded
        }

        if let exact = children.first(where: { $0.lastPathComponent == name }) {
            return (parentPath as NSString).appendingPathComponent(exact.lastPathComponent)
        }
        guard let caseFolded = children.first(where: {
            $0.lastPathComponent.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else {
            return expanded
        }
        return (parentPath as NSString).appendingPathComponent(caseFolded.lastPathComponent)
    }
}
