import Foundation

extension RemnantScanner {
    static func makeItem(
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

    static func makeAppBundleItem(for app: AppInfo) -> RemnantItem? {
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

    static func metadata(at path: String) -> (size: Int64, lastAccessed: Date?)? {
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

    static func resolve(source: SourceAttribution, app: AppInfo) -> SourceAttribution {
        SourceAttribution(
            name: source.name.replacingOccurrences(of: "{appName}", with: app.name),
            bundleID: source.bundleID?.replacingOccurrences(of: "{bundleID}", with: app.bundleID) ?? app.bundleID,
            verifySignature: source.verifySignature
        )
    }
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
