import Foundation

/// A release its source names with a version the app's bundle doesn't carry
/// (Homebrew's `2026.2.2.9` for a bundle that says `2026.2`), tied to the
/// bundle version its download held. Without it the installed copy never
/// compares equal to the release and the update is offered forever.
public struct AppReleaseConfirmedRelease: Codable, Sendable, Equatable {
    /// The source's version, as `AppReleaseVersion.description`.
    public let offered: String
    /// The bundle version that release's download held.
    public let installed: String

    public init(offered: String, installed: String) {
        self.offered = offered
        self.installed = installed
    }
}

public extension AppReleasePreferences {
    /// Whether `candidate` is the release already installed as `app`, learned
    /// from a download Gargantua opened.
    func confirms(_ candidate: AppReleaseCandidate, isInstalledAs app: InstalledApp) -> Bool {
        guard let known = confirmedReleases[app.bundleID] else { return false }
        return known.offered == candidate.version.description && known.installed == app.version.description
    }

    /// Records that `candidate`'s download held bundle version `installed`.
    mutating func confirm(_ candidate: AppReleaseCandidate, holds installed: String, for bundleID: String) {
        confirmedReleases[bundleID] = AppReleaseConfirmedRelease(
            offered: candidate.version.description,
            installed: installed
        )
    }
}

public extension AppReleaseInstallError {
    /// The installed version, when the update was refused because its
    /// download holds exactly that version: the source only names it
    /// differently, and the app is current.
    var versionAlreadyInstalled: String? {
        guard case .verification(.notNewer(let staged, let installed)) = self, staged == installed else { return nil }
        return installed
    }
}
