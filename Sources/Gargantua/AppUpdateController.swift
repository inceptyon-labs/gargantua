import Foundation
import GargantuaCore
import Sparkle
import SwiftUI

@MainActor
final class AppUpdateController: NSObject, ObservableObject {
    let settingsViewModel: AppUpdateSettingsViewModel

    private let updaterDelegate: AppUpdateDelegate
    private let updaterController: SPUStandardUpdaterController
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let settingsViewModel = AppUpdateSettingsViewModel()
        let updaterDelegate = AppUpdateDelegate(settingsViewModel: settingsViewModel)
        self.settingsViewModel = settingsViewModel
        self.updaterDelegate = updaterDelegate
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: Self.hasUsableSparkleConfiguration,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )
        super.init()

        updaterDelegate.updateCycleFinished = { [weak self] in
            self?.refreshSettingsState()
        }
        configureSettingsActions()
        observeUpdater()
        refreshSettingsState()

        if Self.hasUsableSparkleConfiguration {
            updaterController.updater.clearFeedURLFromUserDefaults()
        }
    }

    private func configureSettingsActions() {
        settingsViewModel.checkForUpdates = { [weak self] in
            self?.updaterController.checkForUpdates(nil)
        }
        settingsViewModel.setAutomaticallyChecksForUpdates = { [weak self] value in
            self?.updaterController.updater.automaticallyChecksForUpdates = value
        }
        settingsViewModel.setAutomaticallyDownloadsUpdates = { [weak self] value in
            self?.updaterController.updater.automaticallyDownloadsUpdates = value
        }
        settingsViewModel.setChannel = { [weak self] _ in
            self?.updaterController.updater.resetUpdateCycleAfterShortDelay()
        }
    }

    private func observeUpdater() {
        let updater = updaterController.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshSettingsState() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshSettingsState() }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshSettingsState() }
            },
            updater.observe(\.allowsAutomaticUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshSettingsState() }
            },
        ]
    }

    private func refreshSettingsState() {
        let updater = updaterController.updater
        settingsViewModel.refresh(
            AppUpdateSettingsViewModel.Snapshot(
                automaticallyChecksForUpdates: updater.automaticallyChecksForUpdates,
                automaticallyDownloadsUpdates: updater.automaticallyDownloadsUpdates,
                allowsAutomaticUpdates: updater.allowsAutomaticUpdates,
                canCheckForUpdates: updater.canCheckForUpdates && Self.hasUsableSparkleConfiguration,
                lastUpdateCheckDate: updater.lastUpdateCheckDate,
                feedURL: updater.feedURL
            )
        )
    }

    private static var hasUsableSparkleConfiguration: Bool {
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              feedURL.hasPrefix("https://"),
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return false
        }

        return !publicKey.isEmpty && publicKey != "DRYRUN-SPARKLE-PUBLIC-ED-KEY"
    }
}

@MainActor
private final class AppUpdateDelegate: NSObject, SPUUpdaterDelegate {
    var updateCycleFinished: (() -> Void)?

    private let settingsViewModel: AppUpdateSettingsViewModel

    init(settingsViewModel: AppUpdateSettingsViewModel) {
        self.settingsViewModel = settingsViewModel
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        switch settingsViewModel.channel {
        case .stable: []
        case .beta: Set(["beta"])
        }
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        updateCycleFinished?()
    }
}

struct CheckForUpdatesCommand: View {
    @ObservedObject var viewModel: AppUpdateSettingsViewModel

    var body: some View {
        Button("Check for Updates...") {
            viewModel.userCheckForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
