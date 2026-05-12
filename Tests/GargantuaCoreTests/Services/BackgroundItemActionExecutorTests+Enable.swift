import Foundation
import Testing
@testable import GargantuaCore

extension BackgroundItemActionExecutorTests {
    @Test("User-domain enable runs launchctl enable + bootstrap from plist")
    func enableRebootstraps() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let launchctl = FakeLaunchctl()
        let (executor, writer) = makeExecutor(launchctl: launchctl, auditDir: dir)

        let outcome = await executor.enable(makeItem())

        #expect(outcome.succeeded)
        #expect(launchctl.calls.count == 2)
        #expect(launchctl.calls[0].first == "enable")
        #expect(launchctl.calls[1].first == "bootstrap")

        let entries = try writer.readEntries()
        #expect(entries.first?.command == "enable")
    }
}
