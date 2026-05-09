import Foundation

/// Parsed version label used by stale-version retention decisions.
///
/// The raw label is preserved for display, while numeric components drive
/// ordering across common directory names such as `15.4 (21E219)`,
/// `241.18034.62`, and `android-35`.
public struct StaleVersionIdentifier: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public let numericComponents: [Int]

    public init(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = trimmed
        self.numericComponents = Self.extractNumericComponents(from: trimmed)
    }

    public var description: String { rawValue }

    public static func < (lhs: StaleVersionIdentifier, rhs: StaleVersionIdentifier) -> Bool {
        let count = max(lhs.numericComponents.count, rhs.numericComponents.count)
        for index in 0 ..< count {
            let left = index < lhs.numericComponents.count ? lhs.numericComponents[index] : 0
            let right = index < rhs.numericComponents.count ? rhs.numericComponents[index] : 0
            if left != right { return left < right }
        }
        return lhs.rawValue.localizedStandardCompare(rhs.rawValue) == .orderedAscending
    }

    private static func extractNumericComponents(from raw: String) -> [Int] {
        var components: [Int] = []
        var current = ""

        func flush() {
            guard !current.isEmpty else { return }
            components.append(Int(current) ?? Int.max)
            current = ""
        }

        for scalar in raw.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                current.append(Character(scalar))
            } else {
                flush()
            }
        }
        flush()

        return components
    }
}

/// Retention controls for stale-version discovery.
public struct StaleVersionRetentionPolicy: Sendable, Equatable {
    public let defaultKeepLatest: Int?
    public let keepLatestByFamily: [String: Int]
    public let pinnedPaths: Set<String>
    public let currentVersions: [String: Set<StaleVersionIdentifier>]

    public init(
        defaultKeepLatest: Int? = nil,
        keepLatestByFamily: [String: Int] = [:],
        pinnedPaths: Set<String> = [],
        currentVersions: [String: Set<StaleVersionIdentifier>] = [:]
    ) {
        self.defaultKeepLatest = defaultKeepLatest
        self.keepLatestByFamily = keepLatestByFamily
        self.pinnedPaths = pinnedPaths
        self.currentVersions = currentVersions
    }

    public func keepLatest(for family: StaleVersionFamilyDefinition) -> Int {
        max(1, keepLatestByFamily[family.id] ?? defaultKeepLatest ?? family.keepLatest)
    }

    public func isPinned(path: String) -> Bool {
        let target = Self.normalizedPath(path)
        return pinnedPaths.contains { rawPin in
            let pin = Self.normalizedPath(rawPin)
            guard !pin.isEmpty else { return false }
            if pin.contains("*") {
                return Self.fnmatch(pattern: pin, name: target)
            }
            return target == pin || target.hasPrefix(pin + "/")
        }
    }

    public func currentVersions(for familyID: String) -> Set<StaleVersionIdentifier> {
        currentVersions[familyID] ?? []
    }

    private static func normalizedPath(_ path: String) -> String {
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

/// One versioned directory discovered under a supported tool family.
public struct StaleVersionCandidate: Identifiable, Sendable, Equatable {
    public let familyID: String
    public let productName: String
    public let version: StaleVersionIdentifier
    public let path: String
    public let size: Int64
    public let sourceName: String
    public let category: String
    public let tags: [String]
    public let lastAccessed: Date?

    public var id: String {
        "\(familyID):\(version.rawValue):\(path)"
    }

    public init(
        familyID: String,
        productName: String,
        version: StaleVersionIdentifier,
        path: String,
        size: Int64,
        sourceName: String,
        category: String,
        tags: [String],
        lastAccessed: Date? = nil
    ) {
        self.familyID = familyID
        self.productName = productName
        self.version = version
        self.path = path
        self.size = size
        self.sourceName = sourceName
        self.category = category
        self.tags = tags
        self.lastAccessed = lastAccessed
    }
}

public enum StaleVersionRetentionAction: String, Sendable, Codable, Equatable {
    case keep
    case drop
}

/// Keep/drop decision for one stale-version candidate, with user-facing rationale.
public struct StaleVersionDecision: Sendable, Equatable {
    public let candidate: StaleVersionCandidate
    public let action: StaleVersionRetentionAction
    public let rationale: String

    public init(
        candidate: StaleVersionCandidate,
        action: StaleVersionRetentionAction,
        rationale: String
    ) {
        self.candidate = candidate
        self.action = action
        self.rationale = rationale
    }
}

/// Decisions for one product/family/version set.
public struct StaleVersionGroup: Sendable, Equatable {
    public let familyID: String
    public let productName: String
    public let decisions: [StaleVersionDecision]

    public init(familyID: String, productName: String, decisions: [StaleVersionDecision]) {
        self.familyID = familyID
        self.productName = productName
        self.decisions = decisions
    }
}

/// Configures one versioned directory family for stale-version discovery.
public struct StaleVersionFamilyDefinition: Sendable, Equatable {
    public enum DiscoveryStyle: Sendable, Equatable {
        case immediateChildren
        case jetBrainsToolboxApps
    }

    public let id: String
    public let productName: String
    public let sourceName: String
    public let roots: [URL]
    public let style: DiscoveryStyle
    public let keepLatest: Int
    public let category: String
    public let tags: [String]

    public init(
        id: String,
        productName: String,
        sourceName: String,
        roots: [URL],
        style: DiscoveryStyle,
        keepLatest: Int = 2,
        category: String = "dev_artifacts",
        tags: [String]
    ) {
        self.id = id
        self.productName = productName
        self.sourceName = sourceName
        self.roots = roots
        self.style = style
        self.keepLatest = keepLatest
        self.category = category
        self.tags = tags
    }
}
