import AppKit
import Darwin
import GargantuaAppKitShims
import GargantuaCore
import SwiftUI

@main
struct GargantuaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @AppStorage(MenuBarPreferences.widgetEnabledKey) private var menuBarWidgetEnabled = MenuBarPreferences.defaultWidgetEnabled
    @AppStorage(AppAppearance.userDefaultsKey) private var appearanceRaw = AppAppearance.defaultValue.rawValue
    @StateObject private var updateController: AppUpdateController
    @StateObject private var menuBarStatusModel: MenuBarStatusModel

    private var appearance: AppAppearance { AppAppearance(storedValue: appearanceRaw) }

    init() {
        Self.configureNativeToolTipDelay()
        MetallibStager.stageIfNeeded()
        if CommandLine.arguments.contains("--selfcheck-binaries") {
            Self.runBinarySelfCheck()
        }
        if CommandLine.arguments.contains("--privileged-helper-status") {
            Self.runPrivilegedHelperStatus()
        }
        if CommandLine.arguments.contains("--privileged-helper-register") {
            Self.runPrivilegedHelperRegister()
        }
        if CommandLine.arguments.contains("--privileged-helper-unregister") {
            Self.runPrivilegedHelperUnregister()
        }
        #if DEBUG
            // Debug-only: these drive the root helper on an arbitrary path with no
            // UI or confirmation. A shipped binary must not accept them, or any
            // process running as the user could use the signed app to reach root.
            if let index = CommandLine.arguments.firstIndex(of: "--privileged-helper-smoke-trash") {
                let path = CommandLine.arguments.dropFirst(index + 1).first
                Self.runPrivilegedHelperSmokeTrash(path: path)
            }
            if let index = CommandLine.arguments.firstIndex(of: "--privileged-helper-smoke-empty-trash") {
                let path = CommandLine.arguments.dropFirst(index + 1).first
                Self.runPrivilegedHelperSmokeEmptyTrash(path: path)
            }
        #endif
        _updateController = StateObject(wrappedValue: AppUpdateController())
        _menuBarStatusModel = StateObject(wrappedValue: MenuBarStatusModel())
    }

    @SceneBuilder
    var body: some Scene {
        mainWindowScene
        menuBarScene
    }

    private var mainWindowScene: some Scene {
        WindowGroup("Gargantua", id: "main") {
            MainContentView(updateSettingsViewModel: updateController.settingsViewModel)
                .frame(minWidth: 700, minHeight: 500)
                .preferredColorScheme(appearance.colorScheme)
                .onChange(of: appearanceRaw) { _, _ in
                    AppAppearancePreference.apply(appearance)
                }
                .onOpenURL { url in
                    LicenseActivationLink.handle(url)
                }
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(viewModel: updateController.settingsViewModel)
            }
            GargantuaResultsCommands()
        }
    }

    private var menuBarScene: some Scene {
        MenuBarExtra(isInserted: $menuBarWidgetEnabled) {
            GargantuaMenuBarSceneContent(
                model: menuBarStatusModel,
                updateModel: updateController.settingsViewModel
            )
            .preferredColorScheme(appearance.colorScheme)
        } label: {
            MenuBarStatusLabel(
                snapshot: menuBarStatusModel.snapshot,
                updateAvailable: updateController.settingsViewModel.updateAvailable
            )
        }
        .menuBarExtraStyle(.window)
    }

    private static func configureNativeToolTipDelay() {
        // Macs default to a ~2s delay before the FIRST tooltip in a session
        // fires. After that, hovers feel snappy. We compress the initial delay
        // so the first hover matches the rest. Two paths in case Apple changes
        // the private selector on us:
        //   1) `NSInitialToolTipDelay` user-default (milliseconds, app domain).
        //   2) `NSToolTipManager.setInitialToolTipDelay:` via the Obj-C shim,
        //      which @try/@catches so a missing selector can't crash launch.
        let initialDelayMilliseconds = 250
        UserDefaults.standard.register(defaults: [
            "NSInitialToolTipDelay": initialDelayMilliseconds
        ])
        UserDefaults.standard.set(initialDelayMilliseconds, forKey: "NSInitialToolTipDelay")
        _ = GargantuaSetNativeToolTipDelay(Double(initialDelayMilliseconds) / 1000.0)
    }

    private static func runBinarySelfCheck() -> Never {
        do {
            for line in try VendoredBinarySelfCheck.resolveLines() {
                print(line)
            }
            exit(EXIT_SUCCESS)
        } catch {
            fputs("selfcheck-binaries failed: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func runPrivilegedHelperStatus() -> Never {
        let installer = SMAppServicePrivilegedHelperInstaller()
        print("privileged-helper status: \(installer.status().description)")
        exit(EXIT_SUCCESS)
    }

    private static func runPrivilegedHelperRegister() -> Never {
        let installer = SMAppServicePrivilegedHelperInstaller()
        do {
            let status = try installer.register()
            print("privileged-helper register: \(status.description)")
            exit(EXIT_SUCCESS)
        } catch {
            fputs("privileged-helper register failed: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func runPrivilegedHelperUnregister() -> Never {
        let installer = SMAppServicePrivilegedHelperInstaller()
        do {
            let status = try installer.unregister()
            print("privileged-helper unregister: \(status.description)")
            exit(EXIT_SUCCESS)
        } catch {
            fputs("privileged-helper unregister failed: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    #if DEBUG
        private static func runPrivilegedHelperSmokeTrash(path: String?) -> Never {
            guard let path, !path.isEmpty else {
                fputs("usage: Gargantua --privileged-helper-smoke-trash /Applications/Example.app\n", stderr)
                exit(EXIT_FAILURE)
            }

            let item = PrivilegedUninstallItem(
                id: "smoke",
                path: path,
                category: RemnantCategory.other.rawValue,
                size: 0
            )
            let request = PrivilegedUninstallRequest(planID: UUID(), items: [item], invokingUserID: getuid())
            let helper = XPCPrivilegedUninstallHelper()

            Task { @MainActor in
                let results = await helper.movePrivilegedItemsToTrash(
                    request,
                    authorization: .privilegedHelperApproved
                )
                guard let result = results.first else {
                    fputs("privileged-helper smoke failed: no result returned\n", stderr)
                    exit(EXIT_FAILURE)
                }

                if result.succeeded {
                    print("privileged-helper smoke moved: \(result.item.path)")
                    if let trashURL = result.trashURL {
                        print("trash: \(trashURL.path)")
                    }
                    exit(EXIT_SUCCESS)
                } else {
                    fputs("privileged-helper smoke failed: \(result.error ?? "unknown error")\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
            RunLoop.main.run()
            exit(EXIT_FAILURE)
        }

        private static func runPrivilegedHelperSmokeEmptyTrash(path: String?) -> Never {
            guard let path, !path.isEmpty else {
                fputs("usage: Gargantua --privileged-helper-smoke-empty-trash ~/.Trash/Item\n", stderr)
                exit(EXIT_FAILURE)
            }

            let item = PrivilegedUninstallItem(
                id: "smoke",
                path: path,
                category: RemnantCategory.other.rawValue,
                size: 0,
                operation: .deleteFromTrash
            )
            let request = PrivilegedUninstallRequest(planID: UUID(), items: [item], invokingUserID: getuid())
            let helper = XPCPrivilegedUninstallHelper()

            Task { @MainActor in
                let results = await helper.movePrivilegedItemsToTrash(
                    request,
                    authorization: .privilegedHelperApproved
                )
                guard let result = results.first else {
                    fputs("privileged-helper smoke failed: no result returned\n", stderr)
                    exit(EXIT_FAILURE)
                }

                if result.succeeded {
                    print("privileged-helper smoke deleted from Trash: \(result.item.path)")
                    exit(EXIT_SUCCESS)
                } else {
                    fputs("privileged-helper smoke failed: \(result.error ?? "unknown error")\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
            RunLoop.main.run()
            exit(EXIT_FAILURE)
        }
    #endif
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("GargantuaMainWindow")

    /// Window chrome backdrop. Dark = void hsl(220, 14%, 9%); light = paper
    /// hsl(220, 22%, 96%). Resolves against the window's effective appearance.
    private static let voidWindowBackground = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.0774, green: 0.0858, blue: 0.1026, alpha: 1.0)
        }
        return NSColor(srgbRed: 0.937, green: 0.945, blue: 0.957, alpha: 1.0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        AppAppearancePreference.apply()
        DispatchQueue.main.async { [weak self] in
            self?.configureMainWindow()
            self?.activateMainWindow()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        activateMainWindow()
        return true
    }

    private func configureMainWindow() {
        guard let window = Self.findMainWindow() else { return }

        // Match native AppKit-backed controls (segmented pickers, form fields,
        // popups) to the chosen appearance so they don't render light text on
        // the void background (or vice-versa in light mode).
        window.appearance = AppAppearancePreference.current.nsAppearance

        // Persist window position and size across launches
        window.identifier = Self.mainWindowIdentifier
        window.setFrameAutosaveName("GargantuaMainWindow")

        // Transparent titlebar with full-size content underneath
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)

        // Void background — adapts between the dark void and the light paper
        // canvas so the window chrome behind SwiftUI content matches.
        window.backgroundColor = Self.voidWindowBackground

        // Add an invisible spacer in the titlebar to push traffic lights
        // down from the window edge, giving the "inset" appearance.
        let spacer = NSTitlebarAccessoryViewController()
        spacer.layoutAttribute = .top
        let spacerView = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 8))
        spacer.view = spacerView
        window.addTitlebarAccessoryViewController(spacer)
    }

    static func activateMainWindow() {
        if !activateExistingMainWindow() {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    /// Brings the existing main window to the front without creating a new one.
    /// Returns `false` when no main window exists (e.g. the user closed it), so
    /// callers can decide whether to open a fresh one instead of blindly calling
    /// `openWindow` — which on a `WindowGroup` spawns a duplicate window/tab.
    @discardableResult
    static func activateExistingMainWindow() -> Bool {
        guard let window = findMainWindow() else { return false }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return true
    }

    private func activateMainWindow() {
        Self.activateMainWindow()
    }

    private static func findMainWindow() -> NSWindow? {
        NSApplication.shared.windows.first { $0.identifier == mainWindowIdentifier }
            ?? NSApplication.shared.windows.first { !($0 is NSPanel) && $0.canBecomeKey }
    }
}

private struct GargantuaMenuBarSceneContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: MenuBarStatusModel
    @ObservedObject var updateModel: AppUpdateSettingsViewModel

    var body: some View {
        MenuBarWidgetView(
            model: model,
            updateAvailable: updateModel.updateAvailable,
            updateVersion: updateModel.updateVersion,
            onInstallUpdate: { updateModel.userInstallUpdate() },
            onOpenMainWindow: {
                // Focus the existing main window if it's still open; only fall
                // back to openWindow when there's none, so we don't spawn a
                // duplicate window/tab every time the user taps Open.
                if !AppDelegate.activateExistingMainWindow() {
                    openWindow(id: "main")
                    DispatchQueue.main.async {
                        AppDelegate.activateMainWindow()
                    }
                }
            }
        )
    }
}
