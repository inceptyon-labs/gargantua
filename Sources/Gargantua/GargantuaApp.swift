import AppKit
import GargantuaCore
import SwiftUI

@main
struct GargantuaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            MainContentView()
                .frame(minWidth: 700, minHeight: 500)
        }
        .defaultSize(width: 900, height: 600)
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainWindow()
    }

    private func configureMainWindow() {
        guard let window = NSApplication.shared.windows.first else { return }

        // Persist window position and size across launches
        window.setFrameAutosaveName("GargantuaMainWindow")

        // Transparent titlebar with full-size content underneath
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)

        // Void background — hsl(220, 14%, 9%) converted to RGB
        window.backgroundColor = NSColor(
            red: 0.0774,
            green: 0.0858,
            blue: 0.1026,
            alpha: 1.0
        )

        // Add an invisible spacer in the titlebar to push traffic lights
        // down from the window edge, giving the "inset" appearance.
        let spacer = NSTitlebarAccessoryViewController()
        spacer.layoutAttribute = .top
        let spacerView = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 8))
        spacer.view = spacerView
        window.addTitlebarAccessoryViewController(spacer)
    }
}
