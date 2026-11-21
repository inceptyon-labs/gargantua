import Foundation

/// A release its source names with a version the app's bundle doesn't carry
/// (Homebrew's `2026.2.2.9` for a bundle that says `2026.2`), tied to the
/// bundle version its download held. Without it the installed copy never
/// compares equal to the release and the update is offered forever.
public struct AppReleaseConfirmedRelease: Codable, Sendable, Equatable {
    /// The source's version, as `AppReleaseVersion.description`.
    public let offered: String
    /// The bundle version installed when that release's download was found
    /// to hold it, or to hold an older one.
    public let installed: String
    /// The source that named the release. Another source's release of the
    /// same number is a different download, so it isn't covered. Optional so
    /// an entry stored without it still decodes; such an entry matches nothing.
    public let source: AppReleaseSourceKind?

    public init(offered: String, installed: String, source: AppReleaseSourceKind?) {
        self.offered = offered
        self.installed = installed
        self.source = source
    }
}

public extension AppReleasePreferences {
    /// Whether `candidate` is the release already installed as `app`, learned
    /// from a download Gargantua opened.
    func confirms(_ candidate: AppReleaseCandidate, isInstalledAs app: InstalledApp) -> Bool {
        guard let known = confirmedReleases[app.bundleID] else { return false }
        return known.source == candidate.source
            && known.offered == candidate.version.description
            && known.installed == app.version.description
    }

    /// Records that `candidate`'s download held bundle version `installed`, or
    /// an older one.
    mutating func confirm(_ candidate: AppReleaseCandidate, holds installed: String, for bundleID: String) {
        confirmedReleases[bundleID] = AppReleaseConfirmedRelease(
            offered: candidate.version.description,
            installed: installed,
            source: candidate.source
        )
    }
}

public extension AppReleaseInstallError {
    /// The installed version, when the update was refused because its
    /// download holds exactly that version, which the source only names
    /// differently, or a provably older one, which the app updated itself
    /// past. Either way the app is current.
    var versionAlreadyInstalled: String? {
        guard case .verification(.notNewer(let staged, let installed)) = self,
              staged.description == installed.description || downloadIsOlder
        else { return nil }
        return installed.description
    }

    /// Whether the update was refused because its download holds a version
    /// provably older than the installed one.
    var downloadIsOlder: Bool {
        guard case .verification(.notNewer(let staged, let installed)) = self else { return false }
        return staged.compare(to: installed) == .orderedAscending
    }
}
