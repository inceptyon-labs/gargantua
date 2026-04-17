import Foundation

/// Resolves the directory containing YAML cleanup rules.
///
/// Search order:
/// 1. `GARGANTUA_RULES_DIR` environment variable (dev / test override)
/// 2. `Bundle.module.resourceURL/cleanup_rules` (SPM resource — works for
///    `swift run`, `swift test`, and a shipped `.app` that embeds the
///    `GargantuaCore_GargantuaCore.bundle`)
/// 3. `Bundle.main.resourceURL/cleanup_rules` (flat-copied .app layouts,
///    e.g. a post-build script that places rules directly in `Contents/Resources`)
public enum RuleDirectoryResolver {
    public static func resolve() -> URL? {
        let fm = FileManager.default

        if let envPath = ProcessInfo.processInfo.environment["GARGANTUA_RULES_DIR"], !envPath.isEmpty {
            let url = URL(fileURLWithPath: envPath, isDirectory: true)
            if fm.fileExists(atPath: url.path) { return url }
        }

        if let resourceURL = Bundle.module.resourceURL {
            let candidate = resourceURL.appendingPathComponent("cleanup_rules", isDirectory: true)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        if let mainResourceURL = Bundle.main.resourceURL {
            let candidate = mainResourceURL.appendingPathComponent("cleanup_rules", isDirectory: true)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        return nil
    }
}
