import Foundation
import OSLog

private let logger = Logger(subsystem: "com.gargantua.core", category: "RuleApplicabilityProbe")

/// A coarse classification of which language/tool ecosystem a glob pattern targets.
///
/// Used to short-circuit recursive `**/<leaf>` walks for ecosystems the user does
/// not have any project of. For example, the `dotnet_build_outputs` rule walks for
/// `**/bin/Debug` from `~/Projects` and friends; if no `*.csproj`/`*.sln` exists in
/// any scan root, walking 8 levels deep into every Node/Python/Rust project just to
/// emit a "depth reached. 0 partial results." warning is pure noise.
public enum RuleEcosystem: String, Sendable, CaseIterable {
    case node
    case python
    case rust
    case dotnet
    case terraform
    case serverless
    case zig
    case jvm
}

/// Maps a glob pattern's leaf segment to the ecosystem whose presence justifies walking.
///
/// Patterns whose leaves are ambiguous (e.g. `coverage`, `.nyc_output`, generic names
/// that can apply to any project type) return `nil` — those rules always run.
public enum RulePatternEcosystem {
    /// Returns the ecosystem a `**/<leaf>` pattern is specific to, or `nil` if ambiguous.
    public static func required(for pattern: String) -> RuleEcosystem? {
        // Only `**/...` patterns benefit from pre-checking. Patterns with concrete prefixes
        // (e.g. `~/Projects/**/foo`) get short-circuited by FileManager.fileExists already,
        // and literal patterns are checked the same way.
        guard pattern.hasPrefix("**/") else { return nil }
        let suffix = String(pattern.dropFirst(3))

        switch suffix {
        case "node_modules",
             "node_modules/.cache/webpack",
             "node_modules/.vite",
             ".next/cache",
             ".angular/cache",
             ".svelte-kit",
             ".turbo/cache",
             ".vite/cache",
             ".parcel-cache",
             ".eslintcache",
             ".tsbuildinfo":
            return .node

        case ".venv",
             "venv",
             "__pycache__",
             ".pytest_cache",
             ".mypy_cache",
             ".ruff_cache",
             ".tox":
            return .python

        case "target":
            return .rust

        case ".gradle":
            return .jvm

        case ".zig-cache":
            return .zig

        case ".terraform":
            return .terraform

        case ".serverless",
             ".aws-sam/build":
            return .serverless

        case "bin/Debug",
             "bin/Release",
             "obj":
            return .dotnet

        default:
            return nil
        }
    }
}

/// Detects which ecosystems are represented in the current scan roots.
///
/// Walks each scan root at a shallow depth, scanning directory entries for known
/// project-manifest files (e.g. `package.json`, `Cargo.toml`, `*.csproj`) and a
/// few unambiguous artifact dir leaves (`node_modules`, `.venv`, `target`) that
/// also signal an ecosystem's presence even when the manifest is missing.
///
/// Skips descending into known artifact / dependency directories so we don't waste
/// time walking inside `node_modules`, `.venv`, build outputs, etc.
public struct EcosystemProbe: Sendable {
    public struct Limits: Sendable {
        /// How many directory levels to descend below each scan root.
        public let maxDepth: Int
        /// Cap on total directories visited per probe call.
        public let maxDirectories: Int

        public init(maxDepth: Int = 4, maxDirectories: Int = 5_000) {
            self.maxDepth = maxDepth
            self.maxDirectories = maxDirectories
        }
    }

    public let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Detect every ecosystem represented at depth ≤ `limits.maxDepth` in the given roots.
    ///
    /// Returns the empty set when no roots exist or no signals are found.
    public func detect(in roots: [URL]) -> Set<RuleEcosystem> {
        var found: Set<RuleEcosystem> = []
        var visited = 0
        let target = Set(RuleEcosystem.allCases)
        let fm = FileManager.default

        for root in roots {
            if found == target { break }
            guard fm.fileExists(atPath: root.path) else { continue }
            descend(
                url: root,
                depth: 0,
                found: &found,
                visited: &visited,
                target: target
            )
        }

        logger.debug("EcosystemProbe: detected \(found.map(\.rawValue).joined(separator: ","), privacy: .public) after visiting \(visited) dirs")
        return found
    }

    // MARK: - Internal walk

    private func descend(
        url: URL,
        depth: Int,
        found: inout Set<RuleEcosystem>,
        visited: inout Int,
        target: Set<RuleEcosystem>
    ) {
        if found == target { return }
        if visited >= limits.maxDirectories { return }
        if depth > limits.maxDepth { return }

        visited += 1

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return
        }

        var subdirs: [URL] = []
        subdirs.reserveCapacity(entries.count)

        for entry in entries {
            let name = entry.lastPathComponent

            if let ecosystem = Self.ecosystemSignal(forFileName: name) {
                found.insert(ecosystem)
                if found == target { return }
            }

            // Don't follow symlinks — they often point outside the scan root and
            // would inflate visit counts, especially in dependency caches.
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            guard values?.isDirectory == true else { continue }

            // Treat dependency / artifact dir names as ecosystem signals themselves
            // (a `node_modules` dir alone is enough to know Node is in use), then
            // skip descending into them — there's nothing we want to find inside.
            if let ecosystem = Self.ecosystemSignal(forDirName: name) {
                found.insert(ecosystem)
                if found == target { return }
                continue
            }

            if Self.shouldSkipDescent(into: name) { continue }
            subdirs.append(entry)
        }

        for sub in subdirs {
            if found == target { return }
            descend(
                url: sub,
                depth: depth + 1,
                found: &found,
                visited: &visited,
                target: target
            )
        }
    }

    // MARK: - Signal tables

    /// Files that, when present, identify a project ecosystem.
    private static func ecosystemSignal(forFileName name: String) -> RuleEcosystem? {
        switch name {
        case "package.json":
            return .node
        case "Cargo.toml":
            return .rust
        case "pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "uv.lock", "pdm.lock":
            return .python
        case "build.zig", "build.zig.zon":
            return .zig
        case "build.gradle", "build.gradle.kts",
             "settings.gradle", "settings.gradle.kts",
             "pom.xml", "build.sbt":
            return .jvm
        case "serverless.yml", "serverless.yaml", "serverless.ts", "serverless.js",
             "samconfig.toml":
            return .serverless
        default:
            break
        }

        // Suffix-based matches.
        if name.hasSuffix(".csproj") || name.hasSuffix(".sln")
            || name.hasSuffix(".fsproj") || name.hasSuffix(".vbproj") {
            return .dotnet
        }
        if name.hasSuffix(".tf") || name == "terraform.tfstate" {
            return .terraform
        }
        return nil
    }

    /// Directories whose mere presence signals an ecosystem (and which we then skip).
    ///
    /// These leaf names are ecosystem-specific enough that finding one is itself
    /// proof the ecosystem is in use, even without a sibling manifest. This also
    /// keeps existing tests green: a fixture containing `node_modules` but no
    /// `package.json` still registers as a node project.
    private static func ecosystemSignal(forDirName name: String) -> RuleEcosystem? {
        switch name {
        case "node_modules":
            return .node
        case ".venv", "venv", "__pycache__":
            return .python
        case ".terraform":
            return .terraform
        case ".serverless":
            return .serverless
        case ".zig-cache":
            return .zig
        default:
            return nil
        }
    }

    /// Directories the probe should not descend into.
    ///
    /// Most of these are dependency caches or VCS metadata where any inner manifest
    /// does not represent a user project. Hidden dotdirs are also skipped to keep
    /// the walk fast — project manifests live at the top of project roots.
    private static func shouldSkipDescent(into name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        switch name {
        case "node_modules", "vendor", "Pods",
             "build", "dist", "out", "target",
             "bin", "obj",
             "DerivedData", "Library":
            return true
        default:
            return false
        }
    }
}

/// Strategy for deciding which rules apply to the current scan roots.
///
/// `NativeScanAdapter` consults this before running any glob walks so it can
/// silently skip rules whose required ecosystem has no signal at all.
public protocol RuleApplicabilityChecking: Sendable {
    func availableEcosystems(in scanRoots: [URL]) -> Set<RuleEcosystem>
}

/// Production checker: walks scan roots once and returns detected ecosystems.
public struct DefaultRuleApplicabilityChecker: RuleApplicabilityChecking {
    private let probe: EcosystemProbe

    public init(probe: EcosystemProbe = EcosystemProbe()) {
        self.probe = probe
    }

    public func availableEcosystems(in scanRoots: [URL]) -> Set<RuleEcosystem> {
        probe.detect(in: scanRoots)
    }
}

/// Test/escape-hatch checker that always returns every ecosystem as available.
///
/// Useful when ecosystem-based filtering would interfere with what is being tested,
/// or when a caller already knows the user's environment.
public struct PermissiveRuleApplicabilityChecker: RuleApplicabilityChecking {
    public init() {}

    public func availableEcosystems(in scanRoots: [URL]) -> Set<RuleEcosystem> {
        Set(RuleEcosystem.allCases)
    }
}
