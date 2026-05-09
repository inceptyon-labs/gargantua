import Foundation

/// A known place where local AI tools store downloaded model weights.
public struct AIModelStoreDefinition: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let roots: [URL]
    public let includeExtensionlessLargeFiles: Bool

    public init(
        id: String,
        displayName: String,
        roots: [URL],
        includeExtensionlessLargeFiles: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.roots = roots
        self.includeExtensionlessLargeFiles = includeExtensionlessLargeFiles
    }
}

/// Runtime controls for model-aware cleanup discovery.
public struct AIModelScanPolicy: Sendable {
    public let minimumModelFileSize: Int64
    public let knownStores: [AIModelStoreDefinition]
    public let orphanRoots: [URL]
    public let excludedPaths: Set<String>
    public let protectedRoots: ProtectedRootPolicy
    public let maxDepth: Int
    public let maxEntriesPerRoot: Int
    public let timeBudgetPerRoot: TimeInterval

    public init(
        minimumModelFileSize: Int64 = 100 * 1024 * 1024,
        knownStores: [AIModelStoreDefinition],
        orphanRoots: [URL],
        excludedPaths: Set<String> = [],
        protectedRoots: ProtectedRootPolicy = .loadDefault(),
        maxDepth: Int = 10,
        maxEntriesPerRoot: Int = 100_000,
        timeBudgetPerRoot: TimeInterval = 30
    ) {
        self.minimumModelFileSize = minimumModelFileSize
        self.knownStores = knownStores
        self.orphanRoots = orphanRoots
        self.excludedPaths = excludedPaths
        self.protectedRoots = protectedRoots
        self.maxDepth = maxDepth
        self.maxEntriesPerRoot = maxEntriesPerRoot
        self.timeBudgetPerRoot = timeBudgetPerRoot
    }

    public func isExcluded(path: String) -> Bool {
        let target = Self.normalizedPath(path)
        return excludedPaths.contains { rawPattern in
            let pattern = Self.normalizedPath(rawPattern)
            guard !pattern.isEmpty else { return false }
            if pattern.contains("*") {
                return Self.fnmatch(pattern: pattern, name: target)
            }
            return target == pattern || target.hasPrefix(pattern + "/")
        }
    }

    public func knownStore(for path: String) -> AIModelStoreDefinition? {
        let target = Self.normalizedPath(path)
        return knownStores.first { store in
            store.roots.contains { root in
                let rootPath = Self.normalizedPath(root.path)
                return target == rootPath || target.hasPrefix(rootPath + "/")
            }
        }
    }

    public func protectionReason(for path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        if let exact = protectedRoots.protectionReason(for: url) {
            return exact
        }

        let target = Self.normalizedPath(path)
        for entry in protectedRoots.entries where !entry.path.contains("*") {
            let root = Self.normalizedPath(entry.path)
            if target.hasPrefix(root + "/") {
                return entry.reason
            }
        }
        return nil
    }

    public static func normalizedPath(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private static func fnmatch(pattern: String, name: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var cursor = name.startIndex
        for (index, part) in parts.enumerated() {
            if part.isEmpty { continue }
            if index == 0 && !pattern.hasPrefix("*") {
                guard name.hasPrefix(part) else { return false }
                cursor = name.index(cursor, offsetBy: part.count)
            } else if index == parts.count - 1 && !pattern.hasSuffix("*") {
                return name[cursor...].hasSuffix(part)
            } else {
                guard let range = name.range(of: part, range: cursor ..< name.endIndex) else { return false }
                cursor = range.upperBound
            }
        }
        return true
    }
}

/// One model-looking file discovered under a known store or user-owned folder.
public struct AIModelFileCandidate: Identifiable, Sendable, Equatable {
    public let path: String
    public let fileName: String
    public let fileExtension: String?
    public let size: Int64
    public let sourceName: String
    public let isKnownStore: Bool
    public let modelFamily: String?
    public let lastAccessed: Date?

    public var id: String { path }

    public var duplicateKey: String {
        "\(Self.normalizedDuplicateName(fileName)):\(size)"
    }

    public init(
        path: String,
        fileName: String,
        fileExtension: String?,
        size: Int64,
        sourceName: String,
        isKnownStore: Bool,
        modelFamily: String?,
        lastAccessed: Date?
    ) {
        self.path = path
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.size = size
        self.sourceName = sourceName
        self.isKnownStore = isKnownStore
        self.modelFamily = modelFamily
        self.lastAccessed = lastAccessed
    }

    private static func normalizedDuplicateName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " copy", with: "")
            .replacingOccurrences(of: "-copy", with: "")
    }
}

/// Same-name/same-size model candidates. Contents are deliberately not read.
public struct AIModelDuplicateGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let candidates: [AIModelFileCandidate]

    public var fileName: String { candidates.first?.fileName ?? "Model file" }
    public var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.size } }

    public init(id: String, candidates: [AIModelFileCandidate]) {
        self.id = id
        self.candidates = candidates
    }
}

/// High-level model intelligence findings.
public struct AIModelScanFindings: Sendable, Equatable {
    public let duplicateGroups: [AIModelDuplicateGroup]
    public let orphanCandidates: [AIModelFileCandidate]

    public init(
        duplicateGroups: [AIModelDuplicateGroup],
        orphanCandidates: [AIModelFileCandidate]
    ) {
        self.duplicateGroups = duplicateGroups
        self.orphanCandidates = orphanCandidates
    }
}
