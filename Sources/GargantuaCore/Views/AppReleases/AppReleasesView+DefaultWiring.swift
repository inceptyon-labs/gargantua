import Foundation

extension AppReleasesView {
    /// The production session: real inventory, sources and installer.
    @MainActor
    public static func makeDefaultSession() -> AppReleasesSession {
        AppReleasesSession(
            inventory: DefaultAppReleaseInventory(),
            checker: AppReleaseCheckService.makeDefault(),
            installer: AppReleaseInstaller()
        )
    }
}
