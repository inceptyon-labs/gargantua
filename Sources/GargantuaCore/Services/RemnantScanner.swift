import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "RemnantScanner")

/// Builds uninstall plans for a single app — test seam for the Smart
/// Uninstaller UI.
public protocol UninstallPlanning: Sendable {
    func plan(for app: AppInfo, includeAppBundle: Bool) -> UninstallPlan
}

/// Builds uninstall plans by expanding remnant rules against one app.
public struct RemnantScanner: UninstallPlanning, Sendable {
    private let rules: [RemnantRule]
    private let scanRoots: [URL]
    private let expander: PathExpander

    public init(
        rules: [RemnantRule],
        scanRoots: [URL] = PathExpander.defaultScanRoots(),
        expander: PathExpander = PathExpander()
    ) {
        self.rules = rules
        self.scanRoots = scanRoots
        self.expander = expander
    }

    /// Build a scanner against the bundled `uninstall_rules` directory.
    public static func loadDefaults(scanRoots: [URL]? = nil) throws -> RemnantScanner {
        guard let url = Bundle.module.url(forResource: "uninstall_rules", withExtension: nil) else {
            throw RemnantScannerError.rulesDirectoryNotFound
        }

        let load = try RemnantRuleLoader().loadRules(from: url)
        for error in load.errors {
            logger.warning("Remnant rule parse error: \(error.localizedDescription, privacy: .public)")
        }

        return RemnantScanner(
            rules: load.rules,
            scanRoots: scanRoots ?? PathExpander.defaultScanRoots()
        )
    }

    /// Scan the filesystem for remnants owned by `app`.
    public func plan(for app: AppInfo, includeAppBundle: Bool = true) -> UninstallPlan {
        let applicable = rules.filter { rule in
            rule.appliesTo?.matches(bundleID: app.bundleID) ?? true
        }

        var remnants: [RemnantItem] = []
        var seenPaths: Set<String> = []

        for rule in applicable {
            for item in Self.evaluate(rule: rule, app: app, expander: expander, scanRoots: scanRoots)
                where seenPaths.insert(item.path).inserted {
                remnants.append(item)
            }
        }

        let bundle = includeAppBundle ? Self.makeAppBundleItem(for: app) : nil
        return UninstallPlan(app: app, appBundle: bundle, remnants: remnants)
    }

    /// Expand one template without touching the filesystem.
    public static func expand(template: String, for app: AppInfo) -> String? {
        guard !template.contains("{teamID}") || app.teamIdentifier?.isEmpty == false else {
            return nil
        }

        return template
            .replacingOccurrences(of: "{bundleID}", with: app.bundleID)
            .replacingOccurrences(of: "{appName}", with: app.name)
            .replacingOccurrences(of: "{teamID}", with: app.teamIdentifier ?? "")
    }

    // MARK: - Internal

    private static func evaluate(
        rule: RemnantRule,
        app: AppInfo,
        expander: PathExpander,
        scanRoots: [URL]
    ) -> [RemnantItem] {
        let fileManager = FileManager.default
        var out: [RemnantItem] = []
        var counter = 0

        let expandedExcludes = rule.exclude.compactMap { expand(template: $0, for: app) }

        for template in rule.pathTemplates {
            guard let expanded = expand(template: template, for: app) else { continue }

            let isGlob = expanded.contains("*")
            let paths: [String]
            if isGlob {
                paths = expander.expand(pattern: expanded, roots: scanRoots).paths
            } else {
                let path = (expanded as NSString).expandingTildeInPath
                paths = fileManager.fileExists(atPath: path) ? [path] : []
            }

            for path in paths {
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
                    if isExcluded(url, excludes: expandedExcludes) { continue }
                    if let item = makeItem(rule: rule, app: app, path: path, counter: &counter) {
                        out.append(item)
                    }
                }
            }
        }

        return out
    }

    private struct RuleContext {
        let rule: RemnantRule
        let app: AppInfo
        let excludes: [String]
    }

    private static func enumerateChildren(
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
            if let pattern = context.rule.pattern.flatMap({ expand(template: $0, for: context.app) }),
               !PathExpander.fnmatch(pattern: pattern, name: child.lastPathComponent) {
                continue
            }
            if isExcluded(child, excludes: context.excludes) { continue }
            if let item = makeItem(rule: context.rule, app: context.app, path: child.path, counter: &counter) {
                out.append(item)
            }
        }
    }

    private static func makeItem(
        rule: RemnantRule,
        app: AppInfo,
        path: String,
        counter: inout Int
    ) -> RemnantItem? {
        guard let metadata = metadata(at: path), metadata.size > 0 else { return nil }
        let item = RemnantItem(
            id: "\(rule.id)-\(counter)",
            appBundleID: app.bundleID,
            category: rule.category,
            path: path,
            size: metadata.size,
            safety: rule.safety,
            confidence: rule.confidence,
            explanation: rule.explanation,
            source: resolve(source: rule.source, app: app),
            ruleID: rule.id,
            lastAccessed: metadata.lastAccessed,
            regenerates: rule.regenerates,
            tags: rule.tags
        )
        counter += 1
        return item
    }

    private static func makeAppBundleItem(for app: AppInfo) -> RemnantItem? {
        let path = app.bundlePath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let size = app.sizeOnDisk ?? metadata(at: path)?.size ?? 0
        guard size > 0 else { return nil }

        return RemnantItem(
            id: "app-bundle-\(app.bundleID)",
            appBundleID: app.bundleID,
            category: .other,
            path: path,
            size: size,
            safety: app.isSystemApp ? .protected_ : .review,
            confidence: 95,
            explanation: "Application bundle selected for uninstall.",
            source: SourceAttribution(name: app.name, bundleID: app.bundleID, verifySignature: true),
            ruleID: "app_bundle",
            lastAccessed: metadata(at: path)?.lastAccessed ?? app.lastUsedDate,
            regenerates: false,
            tags: ["app_bundle"]
        )
    }

    private static func metadata(at path: String) -> (size: Int64, lastAccessed: Date?)? {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .contentAccessDateKey,
            .contentModificationDateKey,
        ])

        let size: Int64
        if values?.isDirectory == true {
            size = DirectorySizeScanner.directorySize(at: path).totalSize
        } else {
            let attrs = try? fileManager.attributesOfItem(atPath: path)
            size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }

        return (size, values?.contentAccessDate ?? values?.contentModificationDate)
    }

    private static func resolve(source: SourceAttribution, app: AppInfo) -> SourceAttribution {
        SourceAttribution(
            name: source.name.replacingOccurrences(of: "{appName}", with: app.name),
            bundleID: source.bundleID?.replacingOccurrences(of: "{bundleID}", with: app.bundleID) ?? app.bundleID,
            verifySignature: source.verifySignature
        )
    }

    private static func isExcluded(_ url: URL, excludes: [String]) -> Bool {
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
}

public enum RemnantScannerError: Error, Equatable {
    case rulesDirectoryNotFound
}
