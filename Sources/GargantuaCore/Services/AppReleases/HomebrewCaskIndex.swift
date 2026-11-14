import Foundation
import OSLog

private let caskLogger = Logger(subsystem: "com.gargantua.core", category: "HomebrewCaskIndex")

/// The slice of a Homebrew cask the updater uses.
public struct HomebrewCaskEntry: Sendable, Equatable, Codable {
    public let token: String
    public let name: String?
    public let version: String
    public let url: String?
    /// Nil when the cask declares `no_check`.
    public let sha256: String?
    public let homepage: String?
    /// Installed `.app` names, after any `target` rename.
    public let appNames: [String]
    /// Bundle IDs from `uninstall: quit:`; a trailing `.*` is a prefix wildcard.
    public let quitBundleIDs: [String]
    public let hasPkg: Bool
    public let autoUpdates: Bool
    public let deprecated: Bool
    public let disabled: Bool
    public let hasVariations: Bool

    public init(
        token: String,
        name: String? = nil,
        version: String,
        url: String? = nil,
        sha256: String? = nil,
        homepage: String? = nil,
        appNames: [String] = [],
        quitBundleIDs: [String] = [],
        hasPkg: Bool = false,
        autoUpdates: Bool = false,
        deprecated: Bool = false,
        disabled: Bool = false,
        hasVariations: Bool = false
    ) {
        self.token = token
        self.name = name
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.homepage = homepage
        self.appNames = appNames
        self.quitBundleIDs = quitBundleIDs
        self.hasPkg = hasPkg
        self.autoUpdates = autoUpdates
        self.deprecated = deprecated
        self.disabled = disabled
        self.hasVariations = hasVariations
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

        var appNames: [String] = []
        var quitIDs: [String] = []
        var hasPkg = false
        for case let artifact as [String: Any] in json["artifacts"] as? [Any] ?? [] {
            if let apps = artifact["app"] as? [Any] {
                appNames.append(contentsOf: Self.installedNames(apps))
            }
            if artifact["pkg"] != nil { hasPkg = true }
            let uninstall = artifact["uninstall"]
            let directives = (uninstall as? [Any]) ?? (uninstall as? [String: Any]).map { [$0] } ?? []
            for case let directive as [String: Any] in directives {
                if let quit = directive["quit"] as? String {
                    quitIDs.append(quit)
                } else if let quit = directive["quit"] as? [Any] {
                    quitIDs.append(contentsOf: quit.compactMap { $0 as? String })
                }
            }
        }

        let sha = json["sha256"] as? String
        self.init(
            token: token,
            name: (json["name"] as? [Any])?.compactMap { $0 as? String }.first,
            version: version,
            url: json["url"] as? String,
            sha256: sha == nil || sha == "no_check" || sha?.isEmpty == true ? nil : sha,
            homepage: json["homepage"] as? String,
            appNames: appNames,
            quitBundleIDs: quitIDs,
            hasPkg: hasPkg,
            autoUpdates: json["auto_updates"] as? Bool ?? false,
            deprecated: json["deprecated"] as? Bool ?? false,
            disabled: json["disabled"] as? Bool ?? false,
            hasVariations: !((json["variations"] as? [String: Any])?.isEmpty ?? true)
        )
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

/// Homebrew's cask index with an on-disk cache of the slim entries.
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
/// because the wrong cask would offer another product's download.
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

    public func match(_ app: InstalledApp) -> HomebrewCaskEntry? {
        let candidates = byAppName[app.url.lastPathComponent.lowercased()] ?? []
        let confirmed = candidates.filter { !$0.quitBundleIDs.isEmpty && Self.quits($0, bundleID: app.bundleID) }
        if confirmed.count == 1 { return confirmed[0] }
        if !confirmed.isEmpty { return nil }
        let unconfirmed = candidates.filter(\.quitBundleIDs.isEmpty)
        return unconfirmed.count == 1 ? unconfirmed[0] : nil
    }

    private static func quits(_ entry: HomebrewCaskEntry, bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return entry.quitBundleIDs.contains { quit in
            let quit = quit.lowercased()
            if quit.hasSuffix(".*") { return id.hasPrefix(quit.dropLast()) }
            return quit == id
        }
    }
}

/// Release lookups from Homebrew casks. Best effort: if the index can't load,
/// every app is simply unknown to this source.
public struct HomebrewCaskSource: AppReleaseSourcing {
    public let kind = AppReleaseSourceKind.homebrewCask

    private let index: HomebrewCaskIndex
    private let hostIsArm64: Bool

    public init(index: HomebrewCaskIndex, hostIsArm64: Bool = Self.currentHostIsArm64) {
        self.index = index
        self.hostIsArm64 = hostIsArm64
    }

    #if arch(arm64)
    public static let currentHostIsArm64 = true
    #else
    public static let currentHostIsArm64 = false
    #endif

    public func lookUp(_ apps: [InstalledApp]) async -> [String: AppReleaseSourceOutcome] {
        let entries: [HomebrewCaskEntry]
        do {
            entries = try await index.entries()
        } catch {
            caskLogger.notice("Homebrew cask source unavailable: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
        let matcher = HomebrewCaskMatcher(entries: entries)
        var outcomes: [String: AppReleaseSourceOutcome] = [:]
        for app in apps {
            guard let entry = matcher.match(app) else { continue }
            outcomes[app.bundleID] = outcome(for: entry)
        }
        return outcomes
    }

    private func outcome(for entry: HomebrewCaskEntry) -> AppReleaseSourceOutcome {
        guard let parsed = AppReleaseVersion.cask(entry.version), !parsed.isPrerelease else {
            return .noEligibleRelease
        }
        // The part after a cask's comma is the vendor's build or a hash, not
        // the app's CFBundleVersion, so only the marketing version is compared.
        let version = AppReleaseVersion(short: parsed.short, build: nil)
        let url = entry.url.flatMap(URL.init(string:))
        // Variations may swap the download per architecture; the top-level URL
        // is the arm64 one, so don't hand it to an Intel host.
        let safe = url?.scheme?.lowercased() == "https" && !(entry.hasVariations && !hostIsArm64)
        let downloadURL = safe ? url : nil
        return .found(AppReleaseCandidate(
            source: kind,
            version: version,
            displayVersion: parsed.short,
            downloadURL: downloadURL,
            sha256: entry.sha256,
            payloadKind: entry.hasPkg ? .pkg : .infer(url: downloadURL),
            vendorURL: entry.homepage.flatMap(URL.init(string:)),
            caskToken: entry.token
        ))
    }
}
