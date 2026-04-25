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
    }
}
