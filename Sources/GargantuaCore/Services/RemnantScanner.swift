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
    private let observer: (any ScanProgressObserving)?

    public init(
        rules: [RemnantRule],
        scanRoots: [URL] = PathExpander.defaultScanRoots(),
        expander: PathExpander = PathExpander(),
        observer: (any ScanProgressObserving)? = nil
    ) {
        self.rules = rules
        self.scanRoots = scanRoots
        self.expander = expander
        self.observer = observer
    }

    /// Build a scanner against the bundled `uninstall_rules` directory.
    public static func loadDefaults(
        scanRoots: [URL]? = nil,
        observer: (any ScanProgressObserving)? = nil
    ) throws -> RemnantScanner {
        guard let url = Bundle.module.url(forResource: "uninstall_rules", withExtension: nil) else {
            throw RemnantScannerError.rulesDirectoryNotFound
        }

        let load = try RemnantRuleLoader().loadRules(from: url)
        for error in load.errors {
            logger.warning("Remnant rule parse error: \(error.localizedDescription, privacy: .public)")
        }

        return RemnantScanner(
            rules: load.rules,
            scanRoots: scanRoots ?? PathExpander.defaultScanRoots(),
            observer: observer
        )
    }

    /// Return a copy with a progress observer attached. Useful when the
    /// scanner is built once (e.g. `loadDefaults`) and later wired to a
    /// view-model-owned stream.
    public func withObserver(_ observer: any ScanProgressObserving) -> RemnantScanner {
        RemnantScanner(
            rules: rules,
            scanRoots: scanRoots,
            expander: expander,
            observer: observer
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
            for item in evaluate(rule: rule, app: app)
                where seenPaths.insert(item.path).inserted {
                remnants.append(item)
                observer?.didEmit(ScanProgressEvent(
                    path: item.path,
                    outcome: .match,
                    bytes: item.size
                ))
            }
        }

        let bundle = includeAppBundle ? Self.makeAppBundleItem(for: app) : nil
        if let bundle {
            observer?.didEmit(ScanProgressEvent(
                path: bundle.path,
                outcome: .match,
                bytes: bundle.size
            ))
        }
        return UninstallPlan(app: app, appBundle: bundle, remnants: remnants)
    }

    /// Expand one template without touching the filesystem.
    public static func expand(template: String, for app: AppInfo) -> String? {
        expandAll(template: template, for: app).first
    }

    /// Expand one template into every safe app-name variant it requests.
    ///
    /// `{appNameVariant}` fans out to a bounded, sanitized set containing the
    /// original app name plus no-space, hyphen, underscore, lowercase,
    /// base-channel, and bundle-derived variants.
    public static func expandAll(template: String, for app: AppInfo) -> [String] {
        guard !template.contains("{teamID}") || app.teamIdentifier?.isEmpty == false else {
            return []
        }

        let replacements: [(token: String, values: [String])] = [
            ("{bundleID}", [app.bundleID]),
            ("{bundleName}", bundleDerivedVariants(for: app)),
            ("{appName}", [app.name]),
            ("{appNameNoSpace}", [removeSpaces(app.name)]),
            ("{appNameHyphen}", [joinWords(app.name, separator: "-")]),
            ("{appNameUnderscore}", [joinWords(app.name, separator: "_")]),
            ("{appNameLowercase}", [app.name.lowercased()]),
            ("{appNameBase}", [baseChannelName(app.name)]),
            ("{appNameVariant}", appNameVariants(for: app)),
            ("{teamID}", [app.teamIdentifier ?? ""]),
        ]

        let expanded = replacements.reduce([template]) { current, replacement in
            guard current.contains(where: { $0.contains(replacement.token) }) else {
                return current
            }
            return current.flatMap { candidate in
                replacement.values.map {
                    candidate.replacingOccurrences(of: replacement.token, with: $0)
                }
            }
        }

        return unique(expanded.map { ($0 as NSString).expandingTildeInPath })
    }

    /// Safe app-name variants for broad Mole-style remnant path expansion.
    public static func appNameVariants(for app: AppInfo) -> [String] {
        var candidates: [String] = [app.name]
        if let displayName = app.displayName, displayName != app.name {
            candidates.append(displayName)
        }
        candidates.append(contentsOf: candidates.map(baseChannelName))
        candidates.append(contentsOf: bundleDerivedVariants(for: app))

        var variants: [String] = []
        for candidate in candidates {
            variants.append(candidate)
            variants.append(removeSpaces(candidate))
            variants.append(joinWords(candidate, separator: "-"))
            variants.append(joinWords(candidate, separator: "_"))
            variants.append(candidate.lowercased())
        }

        return unique(variants.compactMap(safeVariant))
    }

    // MARK: - Internal

    private func evaluate(
        rule: RemnantRule,
        app: AppInfo
    ) -> [RemnantItem] {
        let fileManager = FileManager.default
        var out: [RemnantItem] = []
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

        return out
    }

    private struct RuleContext {
        let rule: RemnantRule
        let app: AppInfo
        let excludes: [String]
    }

    private func enumerateChildren(
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

    private static func makeItem(
        rule: RemnantRule,
        app: AppInfo,
        path: String,
        counter: inout Int
    ) -> RemnantItem? {
        guard let metadata = metadata(at: path), metadata.size > 0 else { return nil }
        let preflight = SensitiveDataPreflight.evaluate(path: path, category: rule.category)
        let downgraded = rule.safety == .safe && preflight != nil
        let safety = downgraded ? SafetyLevel.review : rule.safety
        let confidence = downgraded ? min(rule.confidence, 80) : rule.confidence
        let explanation = downgraded ? preflight.map {
            "\(rule.explanation) Sensitive-data preflight matched \($0); review before removal."
        } ?? rule.explanation : rule.explanation
        let tags = downgraded ? unique(rule.tags + ["sensitive_preflight"]) : rule.tags

        let item = RemnantItem(
            id: "\(rule.id)-\(counter)",
            appBundleID: app.bundleID,
            category: rule.category,
            path: path,
            size: metadata.size,
            safety: safety,
            confidence: confidence,
            explanation: explanation,
            source: resolve(source: rule.source, app: app),
            ruleID: rule.id,
            lastAccessed: metadata.lastAccessed,
            regenerates: rule.regenerates,
            tags: tags
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

    private static func bundleDerivedVariants(for app: AppInfo) -> [String] {
        let parts = app.bundleID
            .split(separator: ".")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let last = parts.last else { return [] }
        return unique([last, last.lowercased()])
    }

    private static func baseChannelName(_ name: String) -> String {
        let suffixes = [
            "Alpha", "Beta", "Canary", "Dev", "Developer", "Nightly",
            "Preview", "Release", "Stable", "Insider", "Insiders",
        ]
        let escaped = suffixes.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = #"(?i)(?:[\s._-]+)(\#(escaped))$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return name }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return regex.stringByReplacingMatches(in: name, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeSpaces(_ name: String) -> String {
        name.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private static func joinWords(_ name: String, separator: String) -> String {
        name.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    private static func safeVariant(_ variant: String) -> String? {
        let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\0") else {
            return nil
        }
        return trimmed
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
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

private enum SensitiveDataPreflight {
    static func evaluate(path: String, category: RemnantCategory) -> String? {
        let lower = path.lowercased()
        let componentNames = URL(fileURLWithPath: path).pathComponents.map { $0.lowercased() }

        if category == .cookies || lower.contains("cookie") || lower.contains(".binarycookies") {
            return "cookies"
        }

        if componentNames.contains("documents")
            || componentNames.contains("desktop")
            || componentNames.contains("projects")
            || lower.contains("/document")
            || lower.hasSuffix(".doc")
            || lower.hasSuffix(".docx")
            || lower.hasSuffix(".pdf") {
            return "documents"
        }

        let credentialMarkers = [
            "credential", "credentials", "keychain", "secret", "token",
            "oauth", "password", "passwd", "private key", "id_rsa", ".pem", ".key",
        ]
        if credentialMarkers.contains(where: lower.contains) {
            return "credentials"
        }

        let accountMarkers = [
            "account", "accounts", "identity", "login data", "web data",
            "local state", "profile",
        ]
        if accountMarkers.contains(where: lower.contains) {
            return "account data"
        }

        if category == .preferences
            || lower.contains("preferences")
            || lower.contains("/settings")
            || lower.contains("/config")
            || lower.hasSuffix(".plist") {
            return "settings"
        }

        return nil
    }
}
