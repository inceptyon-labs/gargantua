import Foundation

/// Lightweight filesystem probe that decides which `DevArtifactBucket`
/// ecosystems are actually present on this machine — used by
/// `DevArtifactScanView` to seed a smart default for the category-selection
/// idle state instead of preselecting every bucket on every machine.
///
/// The probe is intentionally shallow: a top-level marker scan of each scan
/// root, capped to two levels deep. It runs once before the user sees the
/// category list and finishes in a few hundred milliseconds for typical dev
/// home directories. It is not a substitute for the real
/// `NativeScanAdapter.scan` — it never reports sizes or item counts.
public enum DevArtifactDetection {

    /// Markers (filename or extension match) that indicate a given ecosystem
    /// has projects on this machine. Order doesn't matter — first match per
    /// ecosystem flips that ecosystem on and we move to the next directory.
    private static let ecosystemMarkers: [(ecosystem: String, names: Set<String>, suffixes: Set<String>)] = [
        ("node", ["package.json", "node_modules", "yarn.lock", "pnpm-lock.yaml"], []),
        ("python", ["requirements.txt", "pyproject.toml", "Pipfile", "setup.py", ".venv", "venv"], []),
        ("rust", ["Cargo.toml", "target"], []),
        ("go", ["go.mod", "go.sum"], []),
        ("jvm", ["build.gradle", "build.gradle.kts", "settings.gradle", "pom.xml", ".gradle"], []),
        ("dotnet", ["packages.config", "global.json"], [".csproj", ".fsproj", ".vbproj", ".sln"]),
        ("ruby", ["Gemfile", "Gemfile.lock", ".bundle"], []),
        ("php", ["composer.json", "composer.lock", "vendor"], []),
        ("xcode", ["Package.swift", ".swiftpm", "DerivedData"], [".xcodeproj", ".xcworkspace"]),
    ]

    /// Cross-cutting buckets are additive across ecosystems and applicable
    /// to almost every developer system, so they're seeded on by default
    /// without requiring detection.
    public static let alwaysSelectedCrossCutting: Set<String> = [
        "build_cache",
        "logs",
        "ai_models",
        "tests",
        "stale_versions",
    ]

    /// Probe `scanRoots` for ecosystem markers. Returns the set of ecosystem
    /// bucket ids that appear to be in use. Always returns `xcode` and
    /// `homebrew` if the system-level checks for them succeed, regardless
    /// of `scanRoots` contents — those don't live in user project trees.
    public static func detectEcosystems(in scanRoots: [URL]) async -> Set<String> {
        var detected: Set<String> = []

        if hasHomebrew() {
            detected.insert("homebrew")
        }
        if hasDockerArtifacts() {
            detected.insert("docker")
        }

        let fm = FileManager.default
        let suffixesAll = Set(ecosystemMarkers.flatMap(\.suffixes))

        for root in scanRoots {
            // First level: the scan root itself.
            scanDirectory(root, fm: fm, suffixesAll: suffixesAll, detected: &detected)
            if detected.count == ecosystemMarkers.count + 2 { return detected }

            // Second level: immediate children (most projects live one
            // directory deep — `~/Projects/some-app/package.json`).
            guard let children = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for child in children {
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                scanDirectory(child, fm: fm, suffixesAll: suffixesAll, detected: &detected)
                if detected.count == ecosystemMarkers.count + 2 { return detected }
            }
        }

        return detected
    }

    /// Add any ecosystem whose markers appear in `directory` to `detected`.
    /// One pass through the directory contents — O(n) per directory — and
    /// we early-exit per ecosystem once it's flagged.
    private static func scanDirectory(
        _ directory: URL,
        fm: FileManager,
        suffixesAll: Set<String>,
        detected: inout Set<String>
    ) {
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        let entrySet = Set(entries)

        for marker in ecosystemMarkers where !detected.contains(marker.ecosystem) {
            if !marker.names.isDisjoint(with: entrySet) {
                detected.insert(marker.ecosystem)
                continue
            }
            if !marker.suffixes.isEmpty {
                for entry in entries {
                    if marker.suffixes.contains(where: { entry.hasSuffix($0) }) {
                        detected.insert(marker.ecosystem)
                        break
                    }
                }
            }
        }
    }

    private static func hasHomebrew() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: "/opt/homebrew/bin/brew")
            || fm.fileExists(atPath: "/usr/local/bin/brew")
    }

    /// Probe Docker by checking the install location and the user's data
    /// directory. We don't shell out to `docker info` — that requires the
    /// daemon to be running and is slow.
    private static func hasDockerArtifacts() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: "/Applications/Docker.app") { return true }
        let home = fm.homeDirectoryForCurrentUser.path
        return fm.fileExists(atPath: "\(home)/Library/Containers/com.docker.docker")
            || fm.fileExists(atPath: "\(home)/.docker")
    }
}
