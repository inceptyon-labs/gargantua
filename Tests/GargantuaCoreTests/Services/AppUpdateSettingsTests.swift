import Foundation
import Testing
@testable import GargantuaCore

@Suite("App update settings")
struct AppUpdateSettingsTests {
    @Test("Channel defaults to stable and persists raw value")
    func channelPersistence() async throws {
        let defaults = try makeDefaults()
        #expect(AppUpdateChannel.stored(in: defaults) == .stable)

        AppUpdateChannel.beta.store(in: defaults)
        #expect(AppUpdateChannel.stored(in: defaults) == .beta)
    }

    @Test("View model dispatches user changes and guards disabled check-now")
    @MainActor
    func viewModelActions() async throws {
        let defaults = try makeDefaults()
        let model = AppUpdateSettingsViewModel(defaults: defaults)
        var checkCount = 0
        var automaticChecks: [Bool] = []
        var automaticDownloads: [Bool] = []
        var channels: [AppUpdateChannel] = []

        model.checkForUpdates = { checkCount += 1 }
        model.setAutomaticallyChecksForUpdates = { automaticChecks.append($0) }
        model.setAutomaticallyDownloadsUpdates = { automaticDownloads.append($0) }
        model.setChannel = { channels.append($0) }

        model.userCheckForUpdates()
        #expect(checkCount == 0)

        model.refresh(
            AppUpdateSettingsViewModel.Snapshot(
                automaticallyChecksForUpdates: true,
                automaticallyDownloadsUpdates: false,
                allowsAutomaticUpdates: true,
                canCheckForUpdates: true,
                lastUpdateCheckDate: nil,
                feedURL: URL(string: "https://gargantua.dev/appcast.xml")
            )
        )

        model.userCheckForUpdates()
        model.userSetAutomaticallyChecksForUpdates(false)
        model.userSetAutomaticallyDownloadsUpdates(true)
        model.userSetChannel(.beta)

        #expect(checkCount == 1)
        #expect(automaticChecks == [false])
        #expect(automaticDownloads == [false])
        #expect(channels == [.beta])
        #expect(AppUpdateChannel.stored(in: defaults) == .beta)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "GargantuaCoreTests.AppUpdateSettings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
