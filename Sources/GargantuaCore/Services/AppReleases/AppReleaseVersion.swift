import Foundation

/// A version as apps and feeds publish it: a marketing (short) version and a
/// build number, either of which may be missing.
///
/// Comparison is deliberately conservative. "Newer" requires positive
/// evidence; anything that can't be compared reads as not newer, so the
/// updater never offers a downgrade or a coin flip.
public struct AppReleaseVersion: Sendable, Equatable, CustomStringConvertible {
    public let short: String?
    public let build: String?

    public init(short: String?, build: String?) {
        self.short = Self.clean(short)
        self.build = Self.clean(build)
    }

    public var description: String {
        switch (short, build) {
        case let (short?, build?) where short != build: "\(short) (\(build))"
        case let (short?, _): short
        case let (nil, build?): build
        case (nil, nil): "unknown"
        }
    }

    /// Whether either component carries a prerelease marker.
    public var isPrerelease: Bool {
        [short, build].compactMap { $0 }.contains { Self.parse($0).prerelease != nil }
    }

    /// Parses a Homebrew cask `version`: `1.2.3,456` is short `1.2.3`, build
    /// `456`. Anything after a second comma, and a `:` suffix, is dropped.
    /// Returns nil for `latest` and empty strings.
    public static func cask(_ raw: String) -> AppReleaseVersion? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "latest" else { return nil }
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false).map {
            String($0.split(separator: ":", maxSplits: 1).first ?? "")
        }
        let short = parts.first
        let build = parts.count > 1 ? parts[1] : nil
        let version = AppReleaseVersion(short: short, build: build)
        return version.short == nil && version.build == nil ? nil : version
    }

    /// Whether `self` is strictly newer than `installed`.
    ///
    /// Marketing versions are compared first. Build numbers break a tie, and
    /// stand in only when one side has no marketing version. A feed that
    /// publishes only a build is compared with the installed build, never with
    /// the installed marketing version, because the two schemes rarely line up.
    public func isNewer(than installed: AppReleaseVersion) -> Bool {
        compare(to: installed) == .orderedDescending
    }

    /// Ordering against another version, or `.orderedSame` when the two can't
    /// be compared.
    public func compare(to other: AppReleaseVersion) -> ComparisonResult {
        if let lhs = short, let rhs = other.short {
            let shortOrder = Self.compareComponent(lhs, rhs)
            if shortOrder != .orderedSame { return shortOrder }
            if let lhsBuild = build, let rhsBuild = other.build {
                return Self.compareComponent(lhsBuild, rhsBuild)
            }
            return .orderedSame
        }
        if let lhsBuild = build, let rhsBuild = other.build {
            return Self.compareComponent(lhsBuild, rhsBuild)
        }
        return .orderedSame
    }

    // MARK: - Parsing

    struct Parsed: Equatable {
        /// Leading dotted numeric core, e.g. `[2, 0, 1]` for `2.0.1-beta3`.
        let numeric: [Int]
        /// Lowercased prerelease tag and its trailing digits, e.g. `beta3`.
        let prerelease: String?
    }

    private static let prereleaseTokens = [
        "alpha", "beta", "preview", "pre", "rc", "dev", "nightly", "canary", "snapshot", "ea", "a", "b",
    ]

    static func parse(_ raw: String) -> Parsed {
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("v"), text.dropFirst().first?.isNumber == true {
            text.removeFirst()
        }

        var numeric: [Int] = []
        var index = text.startIndex
        while index < text.endIndex {
            let digitsEnd = text[index...].firstIndex { !$0.isNumber } ?? text.endIndex
            guard digitsEnd > index, let value = Int(text[index..<digitsEnd]) else { break }
            numeric.append(value)
            index = digitsEnd
            guard index < text.endIndex, text[index] == ".",
                  text.index(after: index) < text.endIndex,
                  text[text.index(after: index)].isNumber
            else { break }
            index = text.index(after: index)
        }

        let remainder = text[index...].drop { "-_. +".contains($0) }
        return Parsed(numeric: numeric, prerelease: prereleaseTag(in: String(remainder)))
    }

    /// A remainder counts as prerelease only when it starts with a known tag
    /// followed by a digit, separator, or end. `2.0 (1234)`, `1.5 build 7`
    /// and `3.1-universal` are not prereleases.
    private static func prereleaseTag(in remainder: String) -> String? {
        guard let first = remainder.first, first.isLetter else { return nil }
        for token in prereleaseTokens where remainder.hasPrefix(token) {
            let rest = remainder.dropFirst(token.count)
            guard let next = rest.first else { return remainder }
            if next.isNumber || "-_. ".contains(next) { return remainder }
        }
        return nil
    }

    static func compareComponent(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = parse(lhs)
        let right = parse(rhs)
        guard !left.numeric.isEmpty, !right.numeric.isEmpty else { return .orderedSame }

        let count = max(left.numeric.count, right.numeric.count)
        for position in 0..<count {
            let leftValue = position < left.numeric.count ? left.numeric[position] : 0
            let rightValue = position < right.numeric.count ? right.numeric[position] : 0
            if leftValue != rightValue {
                return leftValue < rightValue ? .orderedAscending : .orderedDescending
            }
        }

        switch (left.prerelease, right.prerelease) {
        case (nil, nil):
            return .orderedSame
        case (nil, _?):
            return .orderedDescending
        case (_?, nil):
            return .orderedAscending
        case let (leftTag?, rightTag?):
            let order = leftTag.compare(rightTag, options: .numeric)
            return order
        }
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
