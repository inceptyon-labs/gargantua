import Foundation

/// Setapp builds ship with a `-setapp` bundle-ID suffix
/// (`com.bjango.istatmenus-setapp`), so `{bundleID}` templates never reach
/// files a direct-download build of the same app left behind
/// (`/Library/LaunchDaemons/com.bjango.istatmenus.installer.plist`). This pass
/// re-runs the `{bundleID}` rules against the suffix-stripped ID when no app
/// with that ID is installed, and marks what it finds for review.
extension RemnantScanner {
    static let setappSiblingTag = "setapp_sibling"

    /// `com.x.app-setapp` → `com.x.app`; `nil` for any other ID.
    static func setappSiblingBundleID(for bundleID: String) -> String? {
        let suffix = "-setapp"
        guard bundleID.lowercased().hasSuffix(suffix) else { return nil }
        let base = String(bundleID.dropLast(suffix.count))
        guard base.contains("."), !base.hasSuffix(".") else { return nil }
        return base
    }

    /// A template whose `{bundleID}` starts a path component and ends it or
    /// a dot-separated part (`/{bundleID}`, `/{bundleID}.plist`,
    /// `/{bundleID}.*.plist`). With the sibling's shorter ID, a wildcard
    /// running into the ID reaches other apps' data: `{bundleID}*` as
    /// `com.bjango.istatmenus*` also matches iStat Menus 7
    /// (`com.bjango.istatmenus7`), the Setapp build's own files, and a
    /// `/Library/PrivilegedHelperTools` helper of either.
    static func isDelimitedBundleIDTemplate(_ template: String) -> Bool {
        guard let range = template.range(of: "{bundleID}") else { return false }
        let before = template[..<range.lowerBound].last
        let after = template[range.upperBound...].first
        return before == "/" && (after == nil || after == "/" || after == ".")
    }

    func appendSetappSiblingRemnants(
        into remnants: inout [RemnantItem],
        seenPaths: inout Set<String>,
        for app: AppInfo
    ) {
        guard let siblingAppResolver,
              let siblingID = Self.setappSiblingBundleID(for: app.bundleID),
              !siblingAppResolver.isInstalled(bundleID: siblingID) else { return }

        let sibling = AppInfo(
            bundleID: siblingID,
            name: app.name,
            displayName: app.displayName,
            bundlePath: app.bundlePath,
            teamIdentifier: app.teamIdentifier
        )
        let siblingRules: [RemnantRule] = rules.compactMap { rule in
            if let scope = rule.appliesTo {
                return scope.matches(bundleID: siblingID) && !scope.matches(bundleID: app.bundleID) ? rule : nil
            }
            let delimited = rule.pathTemplates.filter(Self.isDelimitedBundleIDTemplate)
            return delimited.isEmpty ? nil : rule.withPathTemplates(delimited)
        }

        for rule in siblingRules {
            for item in evaluate(rule: rule, app: sibling).items
                where seenPaths.insert(item.path).inserted {
                remnants.append(Self.siblingItem(item, app: app, siblingID: siblingID))
                observer?.didEmit(ScanProgressEvent(path: item.path, outcome: .match, bytes: item.size))
            }
        }
    }

    private static func siblingItem(_ item: RemnantItem, app: AppInfo, siblingID: String) -> RemnantItem {
        RemnantItem(
            id: "\(setappSiblingTag)-\(item.id)",
            appBundleID: app.bundleID,
            category: item.category,
            path: item.path,
            size: item.size,
            safety: item.safety == .safe ? .review : item.safety,
            confidence: min(item.confidence, 80),
            explanation: "\(item.explanation) Belongs to \(siblingID), the non-Setapp build of \(app.name); "
                + "review before removal.",
            source: SourceAttribution(
                name: item.source.name,
                bundleID: siblingID,
                verifySignature: item.source.verifySignature
            ),
            ruleID: item.ruleID,
            lastAccessed: item.lastAccessed,
            regenerates: item.regenerates,
            tags: unique(item.tags + [setappSiblingTag]),
            scanTimeResolvedParent: item.scanTimeResolvedParent
        )
    }
}
