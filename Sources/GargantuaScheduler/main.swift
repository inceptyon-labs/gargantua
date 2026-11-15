import Foundation
import GargantuaCore

@main
struct GargantuaSchedulerMain {
    @MainActor
    static func main() async {
        do {
            let persistence = try PersistenceController()
            let runner = ScheduledScanRunner(persistence: persistence)
            _ = await runner.runIfDue()
        } catch {
            FileHandle.standardError.write(Data("GargantuaScheduler failed: \(error.localizedDescription)\n".utf8))
        }

        // Only inside the app bundle: outside it `.standard` would be this agent's own domain.
        if let suite = AppReleaseBackgroundCheck.containingAppSuiteName(),
           let appURL = AppReleaseBackgroundCheck.containingAppURL() {
            let check = AppReleaseBackgroundCheck(
                suiteName: suite,
                inventory: DefaultAppReleaseInventory(),
                checker: AppReleaseCheckService.makeDefault(),
                notifier: ContainingAppUpdateNotifier(suiteName: suite, appURL: appURL)
            )
            _ = await check.runIfDue()
        }
    }
}
