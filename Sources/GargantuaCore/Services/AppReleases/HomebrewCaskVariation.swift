import Foundation

/// One platform's overrides from a cask's `variations`, as written in the index.
public struct HomebrewCaskVariation: Sendable, Equatable, Codable {
    public let url: String?
    /// Raw, so an explicit `no_check` is distinguishable from an absent key.
    public let sha256: String?
    public let version: String?
    /// The key is present with JSON null: this platform has no download or checksum, which is not "inherit".
    public let urlIsNull: Bool
    public let sha256IsNull: Bool
    /// Replaces the top-level requirements wholesale; nil when the variation has no `depends_on`.
    public let dependsOn: HomebrewCaskRequirements?

    public init(
        url: String? = nil,
        sha256: String? = nil,
        version: String? = nil,
        urlIsNull: Bool = false,
        sha256IsNull: Bool = false,
        dependsOn: HomebrewCaskRequirements? = nil
    ) {
        self.url = url
        self.sha256 = sha256
        self.version = version
        self.urlIsNull = urlIsNull
        self.sha256IsNull = sha256IsNull
        self.dependsOn = dependsOn
    }

    init(json: [String: Any]) {
        self.init(
            url: json["url"] as? String,
            sha256: json["sha256"] as? String,
            version: json["version"] as? String,
            urlIsNull: json["url"] is NSNull,
            sha256IsNull: json["sha256"] is NSNull,
            dependsOn: (json["depends_on"] as? [String: Any]).map(HomebrewCaskRequirements.init(json:))
        )
    }
}

/// A cask's `depends_on` as far as the updater honors it: macOS version comparators and CPU architecture.
public struct HomebrewCaskRequirements: Sendable, Equatable, Codable {
    /// Comparator (`>=`, `<=`, `==`) to version strings such as "15" or "10.15".
    public var macOS: [String: [String]]
    /// `type` strings, "arm" or "intel".
    public var arch: [String]

    public init(macOS: [String: [String]] = [:], arch: [String] = []) {
        self.macOS = macOS
        self.arch = arch
    }

    init(json: [String: Any]) {
        var macOS: [String: [String]] = [:]
        for (comparator, value) in json["macos"] as? [String: Any] ?? [:] {
            macOS[comparator] = (value as? [Any])?.compactMap { $0 as? String } ?? []
        }
        let arch = (json["arch"] as? [Any])?.compactMap { ($0 as? [String: Any])?["type"] as? String } ?? []
        self.init(macOS: macOS, arch: arch)
    }

    func allows(_ host: HomebrewCaskHost) -> Bool {
        if !arch.isEmpty, !arch.contains(where: { $0 == "arm" ? host.isArm64 : $0 == "intel" ? !host.isArm64 : false }) {
            return false
        }
        let hostVersion = (host.macOSMajorVersion, 0)
        for (comparator, values) in macOS {
            let versions = values.compactMap(Self.parse)
            switch comparator {
            case ">=": if !versions.allSatisfy({ hostVersion >= $0 }) { return false }
            case "<=": if !versions.allSatisfy({ hostVersion <= $0 }) { return false }
            case "==": if !versions.isEmpty, !versions.contains(where: { hostVersion == $0 }) { return false }
            default: continue
            }
        }
        return true
    }

    private static func parse(_ version: String) -> (Int, Int)? {
        let parts = version.split(separator: ".")
        guard let major = parts.first.flatMap({ Int($0) }) else { return nil }
        return (major, parts.dropFirst().first.flatMap { Int($0) } ?? 0)
    }
}

/// The Mac a cask is resolved for.
public struct HomebrewCaskHost: Sendable, Equatable {
    public var isArm64: Bool
    public var macOSMajorVersion: Int

    public init(isArm64: Bool, macOSMajorVersion: Int) {
        self.isArm64 = isArm64
        self.macOSMajorVersion = macOSMajorVersion
    }

    #if arch(arm64)
        private static let currentIsArm64 = true
    #else
        private static let currentIsArm64 = false
    #endif

    public static let current = HomebrewCaskHost(
        isArm64: currentIsArm64,
        macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    )

    private static let codenames = [14: "sonoma", 15: "sequoia", 26: "tahoe", 27: "golden_gate"]

    /// The `variations` key Homebrew uses for this host; nil for a macOS newer than the table.
    var variationKey: String? {
        Self.codenames[macOSMajorVersion].map { isArm64 ? "arm64_\($0)" : $0 }
    }
}

/// A cask's download as resolved for one host.
struct HomebrewCaskRelease {
    var url: String?
    var sha256: String?
    var version: String
}
