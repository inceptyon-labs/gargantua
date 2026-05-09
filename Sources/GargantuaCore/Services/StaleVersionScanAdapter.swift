import Foundation

/// Discovers old tool/runtime version directories and emits review-gated scan items.
public struct StaleVersionScanAdapter: ScanAdapter {
    public static let resultIDPrefix = "stale-version:"
    public static let tag = "stale-version"
    public static let staleVersionsTag = "stale_versions"
    public static let category = "dev_artifacts"

    private let families: [StaleVersionFamilyDefinition]
    private let policy: StaleVersionRetentionPolicy
    private let categories: Set<String>?

    public init(
        families: [StaleVersionFamilyDefinition],
        policy: StaleVersionRetentionPolicy = StaleVersionRetentionPolicy(),
        categories: Set<String>? = nil
    ) {
        self.families = families
        self.policy = policy
        self.categories = categories
    }

    public static func loadDefaults(
        categories: Set<String>? = nil,
        policy: StaleVersionRetentionPolicy = StaleVersionRetentionPolicy()
    ) -> StaleVersionScanAdapter {
        StaleVersionScanAdapter(
            families: defaultFamilies(),
            policy: policy,
            categories: categories
        )
    }

    public static func defaultFamilies(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [StaleVersionFamilyDefinition] {
        let xcodeRoot = homeDirectory
            .appendingPathComponent("Library/Developer/Xcode", isDirectory: true)
        let xcodePlatforms = ["iOS", "watchOS", "tvOS", "visionOS"]
        let xcodeFamilies = xcodePlatforms.map { platform in
            StaleVersionFamilyDefinition(
                id: "xcode-\(platform.lowercased())-device-support",
                productName: "Xcode \(platform) DeviceSupport",
                sourceName: "Xcode",
                roots: [xcodeRoot.appendingPathComponent("\(platform) DeviceSupport", isDirectory: true)],
                style: .immediateChildren,
                keepLatest: 2,
                tags: ["developer", "xcode", staleVersionsTag]
            )
        }

        let jetBrainsRoot = homeDirectory
            .appendingPathComponent("Library/Application Support/JetBrains/Toolbox/apps", isDirectory: true)
        let jetBrains = StaleVersionFamilyDefinition(
            id: "jetbrains-toolbox",
            productName: "JetBrains Toolbox",
            sourceName: "JetBrains Toolbox",
            roots: [jetBrainsRoot],
            style: .jetBrainsToolboxApps,
            keepLatest: 2,
            tags: ["developer", "jetbrains", staleVersionsTag]
        )

        return xcodeFamilies + [jetBrains]
    }

    public func scan(progress: ScanProgress?) async throws -> [ScanResult] {
        guard categories == nil || categories?.contains(Self.category) == true else { return [] }
        return discoverGroups()
            .flatMap(\.decisions)
            .filter { $0.action == .drop }
            .map(Self.makeScanResult)
    }

    public func discoverGroups() -> [StaleVersionGroup] {
        families.flatMap { family in
            switch family.style {
            case .immediateChildren:
                return discoverImmediateChildGroup(family: family).map { [$0] } ?? []
            case .jetBrainsToolboxApps:
                return discoverJetBrainsGroups(family: family)
            }
        }
    }

    private func discoverImmediateChildGroup(family: StaleVersionFamilyDefinition) -> StaleVersionGroup? {
        let candidates = family.roots.flatMap { root in
            versionDirectories(in: root).map { url in
                makeCandidate(
                    family: family,
                    familyID: family.id,
                    productName: family.productName,
                    versionName: url.lastPathComponent,
                    url: url
                )
            }
        }
        .compactMap(\.self)

        guard !candidates.isEmpty else { return nil }
        return makeGroup(
            familyID: family.id,
            productName: family.productName,
            candidates: candidates,
            keepLatest: policy.keepLatest(for: family)
        )
    }

    private func discoverJetBrainsGroups(family: StaleVersionFamilyDefinition) -> [StaleVersionGroup] {
        family.roots.flatMap { root -> [StaleVersionGroup] in
            versionDirectories(in: root).flatMap { productURL -> [StaleVersionGroup] in
                versionDirectories(in: productURL).compactMap { channelURL in
                    let candidates = versionDirectories(in: channelURL).compactMap { versionURL in
                        makeCandidate(
                            family: family,
                            familyID: jetBrainsFamilyID(product: productURL.lastPathComponent, channel: channelURL.lastPathComponent),
                            productName: "JetBrains \(prettyName(productURL.lastPathComponent)) \(channelURL.lastPathComponent)",
                            versionName: versionURL.lastPathComponent,
                            url: versionURL
                        )
                    }

                    guard !candidates.isEmpty else { return nil }
                    let familyID = jetBrainsFamilyID(
                        product: productURL.lastPathComponent,
                        channel: channelURL.lastPathComponent
                    )
                    return makeGroup(
                        familyID: familyID,
                        productName: "JetBrains \(prettyName(productURL.lastPathComponent)) \(channelURL.lastPathComponent)",
                        candidates: candidates,
                        keepLatest: policy.keepLatest(for: StaleVersionFamilyDefinition(
                            id: familyID,
                            productName: family.productName,
                            sourceName: family.sourceName,
                            roots: family.roots,
                            style: family.style,
                            keepLatest: family.keepLatest,
                            category: family.category,
                            tags: family.tags
                        ))
                    )
                }
            }
        }
    }

    private func makeGroup(
        familyID: String,
        productName: String,
        candidates: [StaleVersionCandidate],
        keepLatest: Int
    ) -> StaleVersionGroup {
        let sortedVersions = Array(Set(candidates.map(\.version))).sorted(by: >)
        let retainedVersions = Set(sortedVersions.prefix(keepLatest))
        let currentVersions = policy.currentVersions(for: familyID)

        let decisions = candidates
            .sorted { lhs, rhs in
                if lhs.version != rhs.version { return lhs.version > rhs.version }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            .map { candidate -> StaleVersionDecision in
                if policy.isPinned(path: candidate.path) {
                    return StaleVersionDecision(
                        candidate: candidate,
                        action: .keep,
                        rationale: "\(candidate.productName) \(candidate.version.rawValue) is pinned by a user exclusion."
                    )
                }
                if currentVersions.contains(candidate.version) {
                    return StaleVersionDecision(
                        candidate: candidate,
                        action: .keep,
                        rationale: "\(candidate.productName) \(candidate.version.rawValue) matches the current or active version hint."
                    )
                }
                if retainedVersions.contains(candidate.version) {
                    return StaleVersionDecision(
                        candidate: candidate,
                        action: .keep,
                        rationale: "\(candidate.productName) \(candidate.version.rawValue) is one of the latest \(keepLatest) retained versions."
                    )
                }
                return StaleVersionDecision(
                    candidate: candidate,
                    action: .drop,
                    rationale: [
                        "\(candidate.productName) \(candidate.version.rawValue) is older than the latest \(keepLatest) retained version(s).",
                        "Old alone is not safe evidence, so Gargantua marks this review and keeps cleanup behind confirmation.",
                    ].joined(separator: " ")
                )
            }

        return StaleVersionGroup(
            familyID: familyID,
            productName: productName,
            decisions: decisions
        )
    }
}

private extension StaleVersionScanAdapter {
    private func versionDirectories(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path),
              let children = try? fm.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return children.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func makeCandidate(
        family: StaleVersionFamilyDefinition,
        familyID: String,
        productName: String,
        versionName: String,
        url: URL
    ) -> StaleVersionCandidate? {
        let size = DirectorySizeScanner.directorySize(at: url.path).totalSize
        guard size > 0 else { return nil }

        let values = try? url.resourceValues(forKeys: [
            .contentAccessDateKey,
            .contentModificationDateKey,
        ])

        return StaleVersionCandidate(
            familyID: familyID,
            productName: productName,
            version: StaleVersionIdentifier(versionName),
            path: url.path,
            size: size,
            sourceName: family.sourceName,
            category: family.category,
            tags: Array(Set(family.tags + [Self.tag, Self.staleVersionsTag])).sorted(),
            lastAccessed: values?.contentAccessDate ?? values?.contentModificationDate
        )
    }

    private static func makeScanResult(decision: StaleVersionDecision) -> ScanResult {
        let candidate = decision.candidate
        return ScanResult(
            id: resultIDPrefix + sanitizedID(candidate.id),
            name: "\(candidate.productName) — \(candidate.version.rawValue)",
            path: candidate.path,
            size: candidate.size,
            safety: .review,
            confidence: 78,
            explanation: decision.rationale,
            source: SourceAttribution(name: candidate.sourceName),
            lastAccessed: candidate.lastAccessed,
            category: candidate.category,
            tags: candidate.tags,
            regenerates: false
        )
    }

    private func jetBrainsFamilyID(product: String, channel: String) -> String {
        "jetbrains-\(Self.sanitizedID(product))-\(Self.sanitizedID(channel))"
    }

    private func prettyName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    private static func sanitizedID(_ raw: String) -> String {
        let mapped = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        return String(mapped)
            .split(separator: "-")
            .joined(separator: "-")
            .lowercased()
    }
}
