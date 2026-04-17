import Foundation

/// Resolves the directory containing YAML cleanup rules.
///
/// Search order:
/// 1. `GARGANTUA_RULES_DIR` environment variable
/// 2. `Bundle.main.resourceURL/cleanup_rules` (shipped .app)
/// 3. `<executable>/cleanup_rules` (same dir as binary)
/// 4. Walk upward from the executable directory looking for a `cleanup_rules/` sibling of `Package.swift` (dev via `swift run`)
public enum RuleDirectoryResolver {
    public static func resolve() -> URL? {
        let fm = FileManager.default

        if let envPath = ProcessInfo.processInfo.environment["GARGANTUA_RULES_DIR"], !envPath.isEmpty {
            let url = URL(fileURLWithPath: envPath, isDirectory: true)
            if fm.fileExists(atPath: url.path) { return url }
        }

        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent("cleanup_rules", isDirectory: true)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        let execDir = Bundle.main.executableURL?.deletingLastPathComponent()
        if let execDir {
            let candidate = execDir.appendingPathComponent("cleanup_rules", isDirectory: true)
            if fm.fileExists(atPath: candidate.path) { return candidate }

            // Walk upward until we find a directory containing both Package.swift and cleanup_rules.
            var dir = execDir
            for _ in 0..<8 {
                let rules = dir.appendingPathComponent("cleanup_rules", isDirectory: true)
                let pkg = dir.appendingPathComponent("Package.swift")
                if fm.fileExists(atPath: rules.path) && fm.fileExists(atPath: pkg.path) {
                    return rules
                }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }

        // Last resort: CWD.
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("cleanup_rules", isDirectory: true)
        if fm.fileExists(atPath: cwd.path) { return cwd }

        return nil
    }
}
