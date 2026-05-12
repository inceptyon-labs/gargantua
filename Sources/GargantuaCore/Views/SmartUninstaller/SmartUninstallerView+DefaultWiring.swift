import SwiftUI

extension SmartUninstallerView {
    // MARK: - Default Wiring

    /// Build the production view model with the default scanner, planner, and
    /// executor wired through the same `PathStreamViewModel`. Public so the
    /// app shell can hoist the instance and let it survive sidebar navigation.
    @MainActor
    public static func makeDefaultViewModel() -> SmartUninstallerViewModel {
        let stream = PathStreamViewModel()
        let scanner = DefaultAppScanner(observer: stream)
        let planner: any UninstallPlanning
        do {
            planner = try RemnantScanner.loadDefaults(observer: stream)
        } catch {
            // Falling back to an empty rule set means the picker still works
            // but plans will only contain the app bundle. Better than a hard
            // crash when the bundled resource is missing in a dev build.
            planner = RemnantScanner(rules: [], observer: stream)
        }
        return SmartUninstallerViewModel(
            appScanner: scanner,
            planner: planner,
            executor: UninstallExecutor(
                privilegedHelper: XPCPrivilegedUninstallHelper(),
                observer: stream
            ),
            authorizationProvider: { .privilegedHelperApproved },
            pathStream: stream
        )
    }
}
