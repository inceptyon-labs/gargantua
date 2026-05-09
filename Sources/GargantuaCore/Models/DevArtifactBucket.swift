import Foundation

/// A grouping shown in `DevArtifactScanView`. Buckets are derived from
/// rule tags + (limited) `ScanResult.category` fallback so the UI surfaces
/// the same ecosystem coverage the cleanup rules already define — no
/// hardcoded list of seven entries that silently hides JVM, .NET, Ruby,
/// PHP, and friends.
public struct DevArtifactBucket: Identifiable, Sendable, Equatable, Hashable {
    /// Top-level grouping of buckets in the UI.
    ///
    /// `ecosystem` buckets are mutually exclusive on the *primary* axis
    /// — a node_modules result belongs in Node, not Python. We pick at
    /// most one ecosystem bucket per result via first-match.
    ///
    /// `crossCutting` buckets are additive — a Gradle build cache is
    /// JVM (ecosystem) AND Build caches (cross-cutting). We accumulate
    /// every matching cross-cutting bucket per result.
    public enum Tier: String, Sendable, Codable {
        case ecosystem
        case crossCutting
    }

    public let id: String
    public let label: String
    /// SF Symbol name. UI tone follows the ink palette for ecosystem and
    /// the accent palette for cross-cutting (set in the view).
    public let icon: String
    public let tier: Tier
    /// Sort order within tier. Lower numbers render first.
    public let priority: Int

    public init(id: String, label: String, icon: String, tier: Tier, priority: Int) {
        self.id = id
        self.label = label
        self.icon = icon
        self.tier = tier
        self.priority = priority
    }
}

// MARK: - Catalog

extension DevArtifactBucket {
    /// The full set of buckets the UI can show. Order is the render order
    /// (within tier — the view groups by tier).
    public static let catalog: [DevArtifactBucket] = [
        // Ecosystem tier — primary, mutually exclusive
        DevArtifactBucket(id: "node", label: "Node", icon: "shippingbox", tier: .ecosystem, priority: 10),
        DevArtifactBucket(id: "python", label: "Python", icon: "chevron.left.forwardslash.chevron.right", tier: .ecosystem, priority: 20),
        DevArtifactBucket(id: "rust", label: "Rust / Cargo", icon: "gearshape.2", tier: .ecosystem, priority: 30),
        DevArtifactBucket(id: "go", label: "Go", icon: "shippingbox.and.arrow.backward", tier: .ecosystem, priority: 40),
        DevArtifactBucket(id: "jvm", label: "JVM", icon: "cup.and.saucer", tier: .ecosystem, priority: 50),
        DevArtifactBucket(id: "dotnet", label: ".NET", icon: "square.stack.3d.up", tier: .ecosystem, priority: 60),
        DevArtifactBucket(id: "ruby", label: "Ruby", icon: "diamond", tier: .ecosystem, priority: 70),
        DevArtifactBucket(id: "php", label: "PHP", icon: "doc.text", tier: .ecosystem, priority: 80),
        DevArtifactBucket(id: "xcode", label: "Xcode", icon: "hammer", tier: .ecosystem, priority: 90),
        DevArtifactBucket(id: "docker", label: "Docker", icon: "cube", tier: .ecosystem, priority: 100),
        DevArtifactBucket(id: "homebrew", label: "Homebrew", icon: "mug", tier: .ecosystem, priority: 110),
        DevArtifactBucket(id: "other", label: "Other", icon: "ellipsis.rectangle", tier: .ecosystem, priority: 999),

        // Cross-cutting tier — additive, can co-exist with any ecosystem
        DevArtifactBucket(id: "build_cache", label: "Build caches", icon: "wrench.and.screwdriver", tier: .crossCutting, priority: 10),
        DevArtifactBucket(id: "logs", label: "Logs", icon: "doc.text.below.ecg", tier: .crossCutting, priority: 20),
        DevArtifactBucket(id: "ai_models", label: "AI / Models", icon: "brain", tier: .crossCutting, priority: 30),
        DevArtifactBucket(id: "tests", label: "Tests", icon: "checkmark.seal", tier: .crossCutting, priority: 40),
        DevArtifactBucket(id: "stale_versions", label: "Stale versions", icon: "clock.arrow.circlepath", tier: .crossCutting, priority: 50),
    ]

    /// Lookup by id; nil if no bucket has that id (programmer error).
    public static func bucket(id: String) -> DevArtifactBucket? {
        catalog.first { $0.id == id }
    }
}

// MARK: - Tag → bucket routing

/// Static routing from a rule `tag` to a bucket id. Tags not in this map
/// don't influence bucket assignment. This is the "tag-driven" half of the
/// design — the rule tagging is the source of truth, this table just
/// names the buckets they roll up into.
///
/// The `bucket(id:)` lookup against `DevArtifactBucket.catalog` is what
/// turns these ids back into full bucket records.
public enum DevArtifactBucketRouting {
    /// First-match-wins routing for ecosystem-tier tags. The order of
    /// the entries here doesn't matter for matching (we iterate the
    /// result's tags) — it matters only when a single rule carries
    /// multiple ecosystem tags, which shouldn't happen in practice.
    public static let ecosystemTags: [String: String] = [
        "node": "node",
        "python": "python",
        "rust": "rust",
        "go": "go",
        "jvm": "jvm",
        "dotnet": "dotnet",
        "ruby": "ruby",
        "php": "php",
        // Low-frequency tags fold into the "Other" ecosystem so they
        // don't each spawn a near-empty section. Re-promote a tag here
        // if its rule count grows enough to deserve its own bucket.
        "deno": "other",
        "elixir": "other",
        "haskell": "other",
        "ocaml": "other",
        "zig": "other",
    ]

    /// Cross-cutting tags add their bucket to a result's bucket set
    /// without competing with ecosystem assignment. Multiple matches
    /// per result are normal (a Gradle log is `logs` AND `build_cache`).
    public static let crossCuttingTags: [String: String] = [
        "build_cache": "build_cache",
        "logs": "logs",
        "ai": "ai_models",
        "models": "ai_models",
        "tests": "tests",
        "stale_versions": "stale_versions",
    ]
}

// MARK: - Derivation

extension DevArtifactBucket {
    /// Map a `ScanResult` to the buckets it should render in. Result is
    /// stable and small (typically 1–2 buckets): exactly one ecosystem
    /// bucket plus zero or more cross-cutting buckets.
    ///
    /// Routing precedence for the ecosystem tier:
    ///
    /// 1. First tag that matches `DevArtifactBucketRouting.ecosystemTags`
    ///    wins. Result tags are iterated in the order the rule lists
    ///    them — rules generally keep ecosystem tags ahead of generic
    ///    ones (`developer`, `cache`).
    /// 2. Category fallback: `docker` → Docker, `homebrew` → Homebrew.
    ///    These rule sets don't carry ecosystem tags but conceptually
    ///    own their own bucket.
    /// 3. Source-name fallback: `Xcode` → Xcode. Xcode rules use the
    ///    shared `dev_artifacts` category and tag themselves with
    ///    `build_cache` rather than an ecosystem tag, so this row is
    ///    needed to keep them out of the "Other" bin.
    /// 4. Anything left lands in "Other" so nothing disappears from the
    ///    UI when a rule's ecosystem isn't in the routing table yet.
    public static func derive(from result: ScanResult) -> [DevArtifactBucket] {
        var buckets: [DevArtifactBucket] = []

        // Ecosystem (first-match wins; exactly one per result)
        let ecosystemID = ecosystemBucketID(for: result)
        if let bucket = DevArtifactBucket.bucket(id: ecosystemID) {
            buckets.append(bucket)
        }

        // Cross-cutting (additive)
        var seenCrossCutting = Set<String>()
        for tag in result.tags {
            guard let bucketID = DevArtifactBucketRouting.crossCuttingTags[tag] else { continue }
            if seenCrossCutting.insert(bucketID).inserted,
               let bucket = DevArtifactBucket.bucket(id: bucketID) {
                buckets.append(bucket)
            }
        }

        return buckets
    }

    private static func ecosystemBucketID(for result: ScanResult) -> String {
        for tag in result.tags {
            if let bucketID = DevArtifactBucketRouting.ecosystemTags[tag] {
                return bucketID
            }
        }
        switch result.category {
        case "docker": return "docker"
        case "homebrew": return "homebrew"
        default: break
        }
        if result.source.name == "Xcode" {
            return "xcode"
        }
        return "other"
    }
}
