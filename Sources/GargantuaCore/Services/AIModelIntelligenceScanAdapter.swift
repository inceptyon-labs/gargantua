import Foundation

/// Finds high-signal local AI model cleanup candidates that static path rules
/// cannot express: same-name/same-size duplicates and orphan model weights.
public struct AIModelIntelligenceScanAdapter: ScanAdapter {
    public static let category = "ai_models"
    public static let resultIDPrefix = "ai-model-intelligence:"
    public static let tag = "ai-model-intelligence"
    public static let duplicateTag = "ai-model-duplicate"
    public static let orphanTag = "ai-model-orphan"

    private static let modelExtensions: Set<String> = [
        "bin", "ckpt", "gguf", "onnx", "pt", "pth", "safetensors",
    ]

    private let policy: AIModelScanPolicy
    private let categories: Set<String>?

    public init(policy: AIModelScanPolicy, categories: Set<String>? = nil) {
        self.policy = policy
        self.categories = categories
    }

    public static func loadDefaults(
        categories: Set<String>? = nil,
        scanRoots: [URL]? = nil,
        excludedPaths: Set<String> = [],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AIModelIntelligenceScanAdapter {
        AIModelIntelligenceScanAdapter(
            policy: AIModelScanPolicy(
                knownStores: defaultKnownStores(homeDirectory: homeDirectory),
                orphanRoots: defaultOrphanRoots(
                    homeDirectory: homeDirectory,
                    scanRoots: scanRoots
                ),
                excludedPaths: excludedPaths
            ),
            categories: categories
        )
    }

    public func scan(progress: ScanProgress?) async throws -> [ScanResult] {
        try await scan(progress: progress, observer: nil)
    }

    public func scan(
        progress: ScanProgress?,
        observer: (any ScanProgressObserving)?
    ) async throws -> [ScanResult] {
        guard categories == nil || categories?.contains(Self.category) == true else { return [] }

        let findings = discoverFindings()
        let results = makeScanResults(from: findings)
        for result in results {
            observer?.didEmit(ScanProgressEvent(
                path: result.path,
                outcome: .match,
                bytes: result.size
            ))
        }
        return results
    }

    public func discoverFindings() -> AIModelScanFindings {
        let candidates = uniqueCandidates()
        let grouped = Dictionary(grouping: candidates, by: \.duplicateKey)
        let duplicateGroups = grouped.values
            .filter { $0.count > 1 }
            .map { group -> AIModelDuplicateGroup in
                let candidates = group.sorted { lhs, rhs in
                    lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                }
                return AIModelDuplicateGroup(
                    id: Self.sanitizedID(candidates.first?.duplicateKey ?? UUID().uuidString),
                    candidates: candidates
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
                return lhs.id < rhs.id
            }

        let duplicatePaths = Set(duplicateGroups.flatMap { $0.candidates.map(\.path) })
        let orphans = candidates
            .filter { !$0.isKnownStore && !duplicatePaths.contains($0.path) }
            .sorted { lhs, rhs in
                if lhs.size != rhs.size { return lhs.size > rhs.size }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }

        return AIModelScanFindings(
            duplicateGroups: duplicateGroups,
            orphanCandidates: orphans
        )
    }
}

private extension AIModelIntelligenceScanAdapter {
    private func uniqueCandidates() -> [AIModelFileCandidate] {
        var byPath: [String: AIModelFileCandidate] = [:]

        for store in policy.knownStores {
            for root in store.roots {
                for candidate in scan(root: root, store: store) {
                    byPath[AIModelScanPolicy.normalizedPath(candidate.path)] = candidate
                }
            }
        }

        for root in policy.orphanRoots {
            for candidate in scan(root: root, store: nil) {
                let key = AIModelScanPolicy.normalizedPath(candidate.path)
                if byPath[key] == nil {
                    byPath[key] = candidate
                }
            }
        }

        return Array(byPath.values)
    }

    private func scan(root: URL, store: AIModelStoreDefinition?) -> [AIModelFileCandidate] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }

        let state = WalkState(
            maxEntries: policy.maxEntriesPerRoot,
            timeBudget: policy.timeBudgetPerRoot
        )
        let context = WalkContext(
            includeHidden: store != nil,
            store: store,
            state: state
        )
        var out: [AIModelFileCandidate] = []
        walk(
            at: root,
            depth: 0,
            context: context,
            into: &out
        )
        return out
    }

    private func walk(
        at url: URL,
        depth: Int,
        context: WalkContext,
        into out: inout [AIModelFileCandidate]
    ) {
        guard !context.state.shouldStop, depth <= policy.maxDepth else { return }
        guard policy.protectionReason(for: url.path) == nil,
              !policy.isExcluded(path: url.path) else {
            return
        }

        let options: FileManager.DirectoryEnumerationOptions = context.includeHidden ? [] : [.skipsHiddenFiles]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .contentAccessDateKey,
                .contentModificationDateKey,
                .fileSizeKey,
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: options
        )) ?? []

        for child in children {
            context.state.incrementEntries()
            if context.state.shouldStop { return }
            if policy.protectionReason(for: child.path) != nil || policy.isExcluded(path: child.path) {
                continue
            }

            let values = try? child.resourceValues(forKeys: [
                .contentAccessDateKey,
                .contentModificationDateKey,
                .fileSizeKey,
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            if values?.isSymbolicLink == true { continue }

            if values?.isDirectory == true {
                walk(
                    at: child,
                    depth: depth + 1,
                    context: context,
                    into: &out
                )
            } else if let candidate = makeCandidate(url: child, values: values, store: context.store) {
                out.append(candidate)
            }
        }
    }

    private func makeCandidate(
        url: URL,
        values: URLResourceValues?,
        store: AIModelStoreDefinition?
    ) -> AIModelFileCandidate? {
        let ext = url.pathExtension.lowercased()
        let extensionMatches = Self.modelExtensions.contains(ext)
        guard extensionMatches || store?.includeExtensionlessLargeFiles == true else { return nil }

        let size = Int64(values?.fileSize ?? 0)
        guard size >= policy.minimumModelFileSize else { return nil }

        let source = store?.displayName ?? "Orphan model file"
        return AIModelFileCandidate(
            path: url.path,
            fileName: url.lastPathComponent,
            fileExtension: ext.isEmpty ? nil : ext,
            size: size,
            sourceName: source,
            isKnownStore: store != nil || policy.knownStore(for: url.path) != nil,
            modelFamily: Self.inferModelFamily(from: url.lastPathComponent),
            lastAccessed: values?.contentAccessDate ?? values?.contentModificationDate
        )
    }

    private func makeScanResults(from findings: AIModelScanFindings) -> [ScanResult] {
        let duplicateResults = findings.duplicateGroups.flatMap(makeDuplicateResults)
        let orphanResults = findings.orphanCandidates.enumerated().map { index, candidate in
            makeOrphanResult(candidate: candidate, index: index)
        }
        return duplicateResults + orphanResults
    }

    private func makeDuplicateResults(group: AIModelDuplicateGroup) -> [ScanResult] {
        group.candidates.enumerated().map { index, candidate in
            ScanResult(
                id: "\(Self.resultIDPrefix)duplicate-\(group.id)-\(index)",
                name: "Duplicate model candidate — \(candidate.fileName)",
                path: candidate.path,
                size: candidate.size,
                safety: .review,
                confidence: 68,
                explanation: duplicateExplanation(group: group, candidate: candidate),
                source: SourceAttribution(name: candidate.sourceName),
                lastAccessed: candidate.lastAccessed,
                category: Self.category,
                tags: tags(
                    candidate: candidate,
                    extra: [Self.duplicateTag, "ai-model-duplicate-group-\(group.id)"]
                ),
                regenerates: false
            )
        }
    }

    private func makeOrphanResult(candidate: AIModelFileCandidate, index: Int) -> ScanResult {
        ScanResult(
            id: "\(Self.resultIDPrefix)orphan-\(Self.sanitizedID(candidate.path))-\(index)",
            name: "Orphan model weight — \(candidate.fileName)",
            path: candidate.path,
            size: candidate.size,
            safety: .review,
            confidence: 64,
            explanation: orphanExplanation(candidate: candidate),
            source: SourceAttribution(name: candidate.sourceName),
            lastAccessed: candidate.lastAccessed,
            category: Self.category,
            tags: tags(candidate: candidate, extra: [Self.orphanTag, "orphan"]),
            regenerates: false
        )
    }

    private func duplicateExplanation(
        group: AIModelDuplicateGroup,
        candidate: AIModelFileCandidate
    ) -> String {
        let family = candidate.modelFamily.map { " Inferred family: \($0)." } ?? ""
        return "\(group.candidates.count) model-looking files share this filename and byte size." +
            "\(family) Gargantua does not inspect model contents, so this stays review-only."
    }

    private func orphanExplanation(candidate: AIModelFileCandidate) -> String {
        let family = candidate.modelFamily.map { " Inferred family: \($0)." } ?? ""
        return "Large \(candidate.fileExtension.map { ".\($0)" } ?? "model") file outside known active model stores." +
            "\(family) Re-download cost and provenance are user-specific, so this stays review-only."
    }

    private func tags(candidate: AIModelFileCandidate, extra: [String]) -> [String] {
        var tags = ["ai", "models", Self.tag] + extra
        if let family = candidate.modelFamily {
            tags.append("model-family-\(Self.sanitizedID(family))")
        }
        return Array(Set(tags)).sorted()
    }

    private static func inferModelFamily(from fileName: String) -> String? {
        let lower = fileName.lowercased()
        let families: [(String, String)] = [
            ("stable-diffusion", "Stable Diffusion"),
            ("sdxl", "Stable Diffusion XL"),
            ("deepseek", "DeepSeek"),
            ("mistral", "Mistral"),
            ("mixtral", "Mixtral"),
            ("llama", "Llama"),
            ("gemma", "Gemma"),
            ("qwen", "Qwen"),
            ("whisper", "Whisper"),
            ("clip", "CLIP"),
            ("bert", "BERT"),
            ("flux", "FLUX"),
            ("phi", "Phi"),
        ]
        return families.first { lower.contains($0.0) }?.1
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

private extension AIModelIntelligenceScanAdapter {
    struct WalkContext {
        let includeHidden: Bool
        let store: AIModelStoreDefinition?
        let state: WalkState
    }

    final class WalkState {
        let maxEntries: Int
        let timeBudget: TimeInterval
        let start = Date()
        var entries = 0

        init(maxEntries: Int, timeBudget: TimeInterval) {
            self.maxEntries = maxEntries
            self.timeBudget = timeBudget
        }

        var shouldStop: Bool {
            entries >= maxEntries || Date().timeIntervalSince(start) > timeBudget
        }

        func incrementEntries() {
            entries += 1
        }
    }
}
