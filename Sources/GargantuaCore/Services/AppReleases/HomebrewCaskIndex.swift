import Foundation
import OSLog

private let caskLogger = Logger(subsystem: "com.gargantua.core", category: "HomebrewCaskIndex")

/// The slice of a Homebrew cask the updater uses.
public struct HomebrewCaskEntry: Sendable, Equatable, Codable {
    public let token: String
    public let version: String
    public let url: String?
    /// Nil when the cask declares `no_check`.
    public let sha256: String?
    public let homepage: String?
    /// Installed `.app` names, after any `target` rename.
    public let appNames: [String]
    /// Bundle IDs from `uninstall: quit:`; a trailing `.*` is a prefix wildcard.
    public let quitBundleIDs: [String]
    /// Dotted names from `zap` and `uninstall`, lowercased, kept only for a
    /// cask with apps and no quit IDs: they are its evidence of which app it
    /// installs. Non-optional so an older cache is refetched.
    public let referencedNames: [String]
    public let hasPkg: Bool
    public let disabled: Bool
    /// Non-optional so a cache written before variations existed fails to decode and is refetched.
    public let variations: [String: HomebrewCaskVariation]
    /// Non-optional for the same reason as `variations`.
    public let dependsOn: HomebrewCaskRequirements
    /// From `url_specs.user_agent`. Non-optional so an older cache is refetched.
    public let downloadAgent: AppReleaseDownloadAgent

    public init(
        token: String,
        version: String,
        url: String? = nil,
        sha256: String? = nil,
        homepage: String? = nil,
        appNames: [String] = [],
        quitBundleIDs: [String] = [],
        referencedNames: [String] = [],
        hasPkg: Bool = false,
        disabled: Bool = false,
        variations: [String: HomebrewCaskVariation] = [:],
        dependsOn: HomebrewCaskRequirements = HomebrewCaskRequirements(),
        downloadAgent: AppReleaseDownloadAgent = .homebrew
    ) {
        self.token = token
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.homepage = homepage
        self.appNames = appNames
        self.quitBundleIDs = quitBundleIDs
        self.referencedNames = referencedNames
        self.hasPkg = hasPkg
        self.disabled = disabled
        self.variations = variations
        self.dependsOn = dependsOn
        self.downloadAgent = downloadAgent
    }

    /// Decodes `cask.json`, skipping entries that are malformed.
    static func decodeAll(from data: Data) throws -> [HomebrewCaskEntry] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw HomebrewCaskIndexError.unexpectedShape
        }
        return array.compactMap { ($0 as? [String: Any]).flatMap(HomebrewCaskEntry.init(json:)) }
    }

    init?(json: [String: Any]) {
        guard let token = json["token"] as? String, !token.isEmpty,
              let version = json["version"] as? String else { return nil }

        let artifacts = HomebrewCaskArtifacts(json["artifacts"])
        let sha = json["sha256"] as? String
        self.init(
            token: token,
            version: version,
            url: json["url"] as? String,
            sha256: sha == nil || sha == "no_check" || sha?.isEmpty == true ? nil : sha,
            homepage: json["homepage"] as? String,
            appNames: artifacts.appNames,
            quitBundleIDs: artifacts.quitBundleIDs,
            referencedNames: artifacts.quitBundleIDs.isEmpty && !artifacts.appNames.isEmpty
                ? artifacts.referencedNames.sorted() : [],
            hasPkg: artifacts.hasPkg,
            disabled: json["disabled"] as? Bool ?? false,
            variations: (json["variations"] as? [String: Any] ?? [:]).compactMapValues { value in
                (value as? [String: Any]).map(HomebrewCaskVariation.init(json:))
            },
            dependsOn: (json["depends_on"] as? [String: Any]).map(HomebrewCaskRequirements.init(json:)) ?? HomebrewCaskRequirements(),
            downloadAgent: AppReleaseDownloadAgent(caskUserAgent: (json["url_specs"] as? [String: Any])?["user_agent"])
        )
    }

    /// The download for `host`: its variation's fields over the top level's. No
    /// download when the host fails `depends_on`, the variation's url or sha256 is
    /// an explicit null, or the macOS is newer than the table on Intel.
    func release(for host: HomebrewCaskHost) -> HomebrewCaskRelease {
        let variation = host.variationKey.flatMap { variations[$0] }
        let requirements = variation?.dependsOn ?? dependsOn
        let blocked = !requirements.allows(host)
            || variation?.urlIsNull == true || variation?.sha256IsNull == true
            || (!variations.isEmpty && host.variationKey == nil && !host.isArm64)
        guard let variation else {
            return HomebrewCaskRelease(url: blocked ? nil : url, sha256: sha256, version: version)
        }
        let checksum = variation.sha256.map { $0 == "no_check" || $0.isEmpty ? nil : $0 } ?? sha256
        return HomebrewCaskRelease(
            url: blocked ? nil : variation.url ?? url, sha256: checksum, version: variation.version ?? version
        )
    }
}

/// The parts of a cask's `artifacts` array the updater reads. The same shape
/// appears in the index, in a Caskroom cask JSON, and as a Caskroom install
/// receipt's `uninstall_artifacts`.
struct HomebrewCaskArtifacts {
    var appNames: [String] = []
    var quitBundleIDs: [String] = []
    /// Dotted path components and identifiers from `zap` and `uninstall`,
    /// lowercased, such as `com.example.app.plist`.
    var referencedNames: Set<String> = []
    var hasPkg = false

    init(_ value: Any?) {
        for case let artifact as [String: Any] in value as? [Any] ?? [] {
            if let apps = artifact["app"] as? [Any] {
                appNames.append(contentsOf: Self.installedNames(apps))
            }
            if artifact["pkg"] != nil { hasPkg = true }
            let uninstall = artifact["uninstall"]
            referencedNames.formUnion(Self.dottedNames(in: uninstall))
            referencedNames.formUnion(Self.dottedNames(in: artifact["zap"]))
            let directives = (uninstall as? [Any]) ?? (uninstall as? [String: Any]).map { [$0] } ?? []
            for case let directive as [String: Any] in directives {
                if let quit = directive["quit"] as? String {
                    quitBundleIDs.append(quit)
                } else if let quit = directive["quit"] as? [Any] {
                    quitBundleIDs.append(contentsOf: quit.compactMap { $0 as? String })
                }
            }
        }
    }

    private static func dottedNames(in value: Any?) -> Set<String> {
        switch value {
        case let text as String:
            let parts = text.lowercased().split { $0 == "/" || $0.isWhitespace }
            return Set(parts.filter { $0.dropFirst().contains(".") }.map(String.init))
        case let list as [Any]:
            return list.reduce(into: []) { $0.formUnion(dottedNames(in: $1)) }
        case let directives as [String: Any]:
            return directives.values.reduce(into: []) { $0.formUnion(dottedNames(in: $1)) }
        default:
            return []
        }
    }

    /// `["Foo.app"]` installs `Foo.app`; `["Foo.app", {"target": "Bar.app"}]` installs `Bar.app`.
    private static func installedNames(_ elements: [Any]) -> [String] {
        var names: [String] = []
        var pending: String?
        for element in elements {
            if let name = element as? String {
                if let pending { names.append(pending) }
                pending = name
            } else if let dict = element as? [String: Any], let target = dict["target"] as? String {
                pending = (target as NSString).lastPathComponent
            }
        }
        if let pending { names.append(pending) }
        return names
    }
}

public enum HomebrewCaskIndexError: Error, LocalizedError, Equatable {
    case unexpectedShape
    case emptyIndex

    public var errorDescription: String? {
        switch self {
        case .unexpectedShape: "The Homebrew cask index has an unexpected format."
        case .emptyIndex: "The Homebrew cask index is empty."
        }
    }
}

/// Homebrew's cask index with an on-disk cache of the slim entries. A cache
/// written with fields this version no longer keeps still decodes, since
/// `JSONDecoder` ignores unknown keys; one missing a field this version needs
/// is refetched.
public actor HomebrewCaskIndex {
    public static let indexURL = URL(string: "https://formulae.brew.sh/api/cask.json")!

    private struct Envelope: Codable {
        var etag: String?
        var fetchedAt: Date
        var entries: [HomebrewCaskEntry]
    }

    private let http: any AppReleaseHTTPFetching
    private let cacheFile: URL
    private let freshFor: TimeInterval
    private let now: @Sendable () -> Date
    private var memory: Envelope?

    public init(
        http: any AppReleaseHTTPFetching,
        cacheDirectory: URL = HomebrewCaskIndex.defaultCacheDirectory(),
        freshFor: TimeInterval = 600,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.http = http
        self.cacheFile = cacheDirectory.appendingPathComponent("homebrew-casks.json")
        self.freshFor = freshFor
        self.now = now
    }

    public static func defaultCacheDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("com.gargantua.core", isDirectory: true)
            .appendingPathComponent("AppReleases", isDirectory: true)
    }

    public func entries() async throws -> [HomebrewCaskEntry] {
        let cached = memory ?? readCache()
        if let cached, now().timeIntervalSince(cached.fetchedAt) < freshFor {
            memory = cached
            return cached.entries
        }

        do {
            let response = try await http.get(Self.indexURL, etag: cached?.etag)
            if response.isNotModified, var cached {
                cached.fetchedAt = now()
                store(cached)
                return cached.entries
            }
            let data = response.data
            let entries = try await Task.detached { try HomebrewCaskEntry.decodeAll(from: data) }.value
            guard !entries.isEmpty else { throw HomebrewCaskIndexError.emptyIndex }
            let envelope = Envelope(etag: response.etag, fetchedAt: now(), entries: entries)
            store(envelope)
            return entries
        } catch {
            caskLogger.notice("Homebrew cask index fetch failed: \(error.localizedDescription, privacy: .public)")
            if let cached { return cached.entries }
            throw error
        }
    }

    private func readCache() -> Envelope? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Envelope.self, from: data)
    }

    private func store(_ envelope: Envelope) {
        memory = envelope
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(envelope) else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: cacheFile, options: .atomic)
        } catch {
            caskLogger.warning("Homebrew cask cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Maps installed apps to casks. Fails closed: an ambiguous match is no match,
/// because the wrong cask would offer another product's download. A shared
/// `.app` filename alone is not a match either: apps from different vendors
/// can have the same name.
public struct HomebrewCaskMatcher: Sendable {
    private let byAppName: [String: [HomebrewCaskEntry]]

    public init(entries: [HomebrewCaskEntry]) {
        var index: [String: [HomebrewCaskEntry]] = [:]
        for entry in entries where !entry.disabled {
            for name in Set(entry.appNames.map { $0.lowercased() }) {
                index[name, default: []].append(entry)
            }
        }
        byAppName = index
    }

    /// - Parameter installedTokens: Casks Homebrew has installed on this Mac.
    ///   One with the app's filename and no quit IDs is taken to be its cask,
    ///   and an installed cask settles a tie between casks that both qualify.
    public func match(_ app: InstalledApp, installedTokens: Set<String> = []) -> HomebrewCaskEntry? {
        let candidates = byAppName[app.url.lastPathComponent.lowercased()] ?? []
        let confirmed = candidates.filter { !$0.quitBundleIDs.isEmpty && Self.quits($0, bundleID: app.bundleID) }
        if !confirmed.isEmpty { return Self.single(confirmed, installedTokens: installedTokens) }
        let supported = candidates.filter { entry in
            entry.quitBundleIDs.isEmpty && (
                installedTokens.contains(entry.token) || Self.references(entry.referencedNames, bundleID: app.bundleID)
            )
        }
        return Self.single(supported, installedTokens: installedTokens)
    }

    /// The one candidate, or, among siblings such as `foo` and `foo@beta`,
    /// the only one Homebrew has installed.
    private static func single(_ candidates: [HomebrewCaskEntry], installedTokens: Set<String>) -> HomebrewCaskEntry? {
        if candidates.count == 1 { return candidates[0] }
        let installed = candidates.filter { installedTokens.contains($0.token) }
        return installed.count == 1 ? installed[0] : nil
    }

    /// Whether a name contains the bundle ID as whole dot-separated parts, so
    /// `com.foo.bar.plist` and `TEAM.com.foo.bar` name `com.foo.bar` but
    /// `com.foo.barista` doesn't. A trailing `*` is a wildcard in cask paths.
    static func references(_ names: [String], bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        guard id.contains(".") else { return false }
        return names.contains { name in
            var searchStart = name.startIndex
            while let found = name.range(of: id, range: searchStart ..< name.endIndex) {
                let startsPart = found.lowerBound == name.startIndex || name[name.index(before: found.lowerBound)] == "."
                let endsPart = found.upperBound == name.endIndex || ".*".contains(name[found.upperBound])
                if startsPart, endsPart { return true }
                searchStart = name.index(after: found.lowerBound)
            }
            return false
        }
    }

    private static func quits(_ entry: HomebrewCaskEntry, bundleID: String) -> Bool {
        quits(entry.quitBundleIDs, bundleID: bundleID)
    }

    static func quits(_ quitBundleIDs: [String], bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return quitBundleIDs.contains { quit in
            let quit = quit.lowercased()
            if quit.hasSuffix(".*") { return id.hasPrefix(quit.dropLast()) }
            return quit == id
        }
    }
}

/// What the Homebrew source learned about the apps it matched to a cask.
public struct HomebrewCaskLookup: Sendable, Equatable {
    /// The release each matched cask offers, by bundle ID.
    public var outcomes: [String: AppReleaseSourceOutcome] = [:]
    /// The matched cask token for every matched app, whatever the cask's
    /// version says, so a brew-installed app is recognized even when its
    /// cask offers nothing usable (`version :latest`, a beta).
    public var tokens: [String: String] = [:]

    public init(outcomes: [String: AppReleaseSourceOutcome] = [:], tokens: [String: String] = [:]) {
        self.outcomes = outcomes
        self.tokens = tokens
    }
}

/// Release lookups from Homebrew casks. Best effort: if the index can't load,
/// every app is simply unknown to this source.
///
/// Not an `AppReleaseSourcing`: the check service also needs the matched
/// tokens to tell which apps brew manages, so it takes this source directly.
public struct HomebrewCaskSource: Sendable {
    private let index: HomebrewCaskIndex
    private let host: HomebrewCaskHost

    public init(index: HomebrewCaskIndex, host: HomebrewCaskHost = .current) {
        self.index = index
        self.host = host
    }

    public func lookUp(_ apps: [InstalledApp], installedTokens: Set<String> = []) async -> HomebrewCaskLookup {
        let entries: [HomebrewCaskEntry]
        do {
            entries = try await index.entries()
        } catch {
            caskLogger.notice("Homebrew cask source unavailable: \(error.localizedDescription, privacy: .public)")
            return HomebrewCaskLookup()
        }
        let matcher = HomebrewCaskMatcher(entries: entries)
        var lookup = HomebrewCaskLookup()
        for app in apps {
            guard let entry = matcher.match(app, installedTokens: installedTokens) else { continue }
            lookup.outcomes[app.bundleID] = outcome(for: entry, installed: app.version)
            lookup.tokens[app.bundleID] = entry.token
        }
        return lookup
    }

    private func outcome(for entry: HomebrewCaskEntry, installed: AppReleaseVersion) -> AppReleaseSourceOutcome {
        let release = entry.release(for: host)
        guard let parsed = AppReleaseVersion.cask(release.version), !parsed.isPrerelease else {
            return .noEligibleRelease
        }
        // The part after a cask's comma is the vendor's build or a hash, not
        // the app's CFBundleVersion, so only the marketing version is compared.
        let version = AppReleaseVersion(short: installed.marketingVersion(ofCask: parsed.short), build: nil)
        let downloadURL = release.url.flatMap(URL.init(string:))?.httpsOnly
        return .found(AppReleaseCandidate(
            source: .homebrewCask,
            version: version,
            displayVersion: parsed.short,
            downloadURL: downloadURL,
            sha256: release.sha256,
            payloadKind: entry.hasPkg ? .pkg : .infer(url: downloadURL),
            vendorURL: entry.homepage.flatMap(URL.init(string:)),
            caskToken: entry.token,
            caskVersion: release.version,
            downloadAgent: entry.downloadAgent
        ))
    }
}
