import Foundation

/// One platform's overrides from a cask's `variations`, as written in the index.
public struct HomebrewCaskVariation: Sendable, Equatable, Codable {
    public let url: String?
    /// Raw, so an explicit `no_check` is distinguishable from an absent key.
    public let sha256: String?
    public let version: String?

    public init(url: String? = nil, sha256: String? = nil, version: String? = nil) {
        self.url = url
        self.sha256 = sha256
        self.version = version
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
