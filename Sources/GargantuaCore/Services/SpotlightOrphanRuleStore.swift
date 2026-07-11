import Foundation
import GargantuaLicensing

#if canImport(AppKit)
    import AppKit
#endif

/// Production reader/writer for the user-domain `com.apple.Spotlight`
/// `EnabledPreferenceRules` store.
///
/// `EnabledPreferenceRules` is a flat array of bundle-id strings (verified
/// on-device, and matching Mole #1000). Each entry is either a third-party
/// reverse-DNS bundle id or a `System.*` / `com.apple.*` system rule. Pruning
/// rewrites the array; it never edits the plist file in place, because cfprefsd
/// owns the cache and would clobber a direct file write.
public struct CFPreferencesSpotlightRulesStore: SpotlightRulesReading, SpotlightRulesWriting {
    public static let defaultDomain = "com.apple.Spotlight"
    public static let key = "EnabledPreferenceRules"

    private let domain: String

    public init(domain: String = CFPreferencesSpotlightRulesStore.defaultDomain) {
        self.domain = domain
    }

    public func enabledRuleIdentifiers() -> [String] {
        let value = CFPreferencesCopyAppValue(Self.key as CFString, domain as CFString)
        return (value as? [String]) ?? []
    }

    public func write(keptIdentifiers: [String]) throws {
        // Rewrite through cfprefsd. An empty result drops the key entirely
        // (mirrors Mole #1000's `defaults delete`) so System Settings reflects a
        // fully-clean state rather than a lingering empty array.
        let newValue: CFPropertyList? = keptIdentifiers.isEmpty ? nil : (keptIdentifiers as CFArray)
        CFPreferencesSetAppValue(Self.key as CFString, newValue, domain as CFString)
        guard CFPreferencesAppSynchronize(domain as CFString) else {
            throw SpotlightRulesStoreError.synchronizeFailed
        }
    }
}

public enum SpotlightRulesStoreError: Error, Sendable, Equatable {
    case synchronizeFailed
}

/// Removes a single app's rule from the Spotlight preference store — the
/// per-app path used by the Smart Uninstaller (vs. the batch orphan prune).
public protocol SpotlightRuleRemoving: Sendable {
    func remove(bundleID: String) throws
}

public struct StoreSpotlightRuleRemover: SpotlightRuleRemoving {
    private let store: any SpotlightRulesReading & SpotlightRulesWriting

    public init(store: CFPreferencesSpotlightRulesStore = CFPreferencesSpotlightRulesStore()) {
        self.store = store
    }

    public func remove(bundleID: String) throws {
        let ids = store.enabledRuleIdentifiers()
        guard ids.contains(bundleID) else { return } // already absent — no-op
        try store.write(keptIdentifiers: ids.filter { $0 != bundleID })
    }
}

/// Resolves whether a bundle id is installed, layering three checks so a stale
/// LaunchServices database can't make an installed app look "gone" (the false
/// positive that would wrongly flag a Spotlight rule as orphaned). Mirrors
/// Mole's `bundle_has_installed_app` (tw93/Mole): LaunchServices → mdfind →
/// filesystem scan. Any hit means installed; only an all-miss means gone.
public struct WorkspaceInstalledAppResolver: OwningAppResolving {
    private let appRoots: [URL]
    // FileManager isn't Sendable, but this resolver only issues read-only,
    // thread-safe queries against it (and defaults to the shared instance).
    nonisolated(unsafe) private let fileManager: FileManager
    private let processRunner: any ProcessRunner
    private let workspaceLookup: @Sendable (String) -> Bool
    /// Helper bundle ids (`…​.helper`/`.daemon`/`.agent`/`.xpc`) often belong to
    /// a parent app; if the parent is installed, the helper is not orphaned.
    private static let helperSuffixes = [".helper", ".daemon", ".agent", ".xpc"]

    public init(
        appRoots: [URL] = WorkspaceInstalledAppResolver.defaultAppRoots(),
        fileManager: FileManager = .default,
        processRunner: any ProcessRunner = DefaultProcessRunner(),
        workspaceLookup: @escaping @Sendable (String) -> Bool = WorkspaceInstalledAppResolver.launchServicesLookup
    ) {
        self.appRoots = appRoots
        self.fileManager = fileManager
        self.processRunner = processRunner
        self.workspaceLookup = workspaceLookup
    }

    public static func defaultAppRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            + [homeDirectory.appendingPathComponent("Applications", isDirectory: true)]
    }

    public static let launchServicesLookup: @Sendable (String) -> Bool = { bundleID in
        #if canImport(AppKit)
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        #else
            return false
        #endif
    }

    public func isInstalled(bundleID: String) -> Bool {
        guard Self.isSafeBundleID(bundleID) else { return false }
        return workspaceLookup(bundleID)
            || mdfindHasMatch(bundleID)
            || filesystemHasApp(bundleID)
    }

    /// `true` when any installed app's bundle identifier starts with
    /// `bundleIDPrefix` (e.g. `"com.valvesoftware."`). Vendor-prefix sibling
    /// of `isInstalled(bundleID:)`, used when a background item's launchd
    /// label carries no enclosing-bundle id to resolve exactly.
    public func isAnyAppInstalled(bundleIDPrefix: String) -> Bool {
        let candidate = bundleIDPrefix.hasSuffix(".") ? String(bundleIDPrefix.dropLast()) : bundleIDPrefix
        guard Self.isSafeBundleID(candidate) else { return false }
        return mdfindHasPrefixMatch(bundleIDPrefix) || filesystemHasAppWithPrefix(bundleIDPrefix)
    }

    /// Allow only well-formed bundle ids so nothing unsafe is interpolated into
    /// the mdfind query.
    static func isSafeBundleID(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty, bundleID.contains(".") else { return false }
        return bundleID.allSatisfy { ch in
            ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_"
        }
    }

    private func mdfindHasMatch(_ bundleID: String) -> Bool {
        let output = try? processRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/mdfind"),
            arguments: ["kMDItemCFBundleIdentifier == '\(bundleID)'"],
            timeout: 2,
            maxCapturedBytes: 64 * 1024
        )
        guard let output, output.exitCode == 0 else { return false }
        return !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func mdfindHasPrefixMatch(_ bundleIDPrefix: String) -> Bool {
        let output = try? processRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/mdfind"),
            arguments: ["kMDItemCFBundleIdentifier == '\(bundleIDPrefix)*'"],
            timeout: 2,
            maxCapturedBytes: 64 * 1024
        )
        guard let output, output.exitCode == 0 else { return false }
        return !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func filesystemHasAppWithPrefix(_ bundleIDPrefix: String) -> Bool {
        for root in appRoots {
            guard let apps = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for app in apps where app.pathExtension == "app" {
                guard let appBundleID = Self.infoPlistBundleID(of: app, fileManager: fileManager) else { continue }
                if appBundleID.hasPrefix(bundleIDPrefix) { return true }
            }
        }
        return false
    }

    private func filesystemHasApp(_ bundleID: String) -> Bool {
        let parentID = Self.helperSuffixes.lazy
            .first { bundleID.hasSuffix($0) }
            .map { String(bundleID.dropLast($0.count)) }

        for root in appRoots {
            guard let apps = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for app in apps where app.pathExtension == "app" {
                // A helper bundle embedded inside a parent app.
                let embedded = app.appendingPathComponent("Contents/Library/LaunchServices/\(bundleID)")
                if fileManager.fileExists(atPath: embedded.path) { return true }

                guard let appBundleID = Self.infoPlistBundleID(of: app, fileManager: fileManager) else { continue }
                if appBundleID == bundleID || (parentID != nil && appBundleID == parentID) {
                    return true
                }
            }
        }
        return false
    }

    static func infoPlistBundleID(of app: URL, fileManager: FileManager) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = fileManager.contents(atPath: plist.path),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict["CFBundleIdentifier"] as? String
    }
}

extension SpotlightOrphanRuleScanner {
    /// Wires the production CFPreferences store, LaunchServices resolver, and
    /// the licensing destructive-action gate.
    public static func live() -> SpotlightOrphanRuleScanner {
        let store = CFPreferencesSpotlightRulesStore()
        return SpotlightOrphanRuleScanner(
            reader: store,
            writer: store,
            resolver: WorkspaceInstalledAppResolver(),
            canExecuteDestructive: {
                if case .allowed = await LicenseGate.shared.canExecuteDestructiveAction() {
                    return true
                }
                return false
            }
        )
    }
}
