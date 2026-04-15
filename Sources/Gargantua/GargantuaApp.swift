import AppKit
import GargantuaCore
import SwiftUI

@main
struct GargantuaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            MainContentView()
                .frame(minWidth: 700, minHeight: 450)
        }
        .defaultSize(width: 900, height: 600)
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Vertical/horizontal inset for traffic light buttons from the window edge.
    private static let trafficLightInset = CGPoint(x: 20, y: 20)

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainWindow()
    }

    private func configureMainWindow() {
        guard let window = NSApplication.shared.windows.first else { return }

        // Transparent titlebar with full-size content underneath
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)

        // Void background — hsl(220, 14%, 9%) converted to RGB
        // Using the same HSL→RGB math as DesignTokens.swift
        window.backgroundColor = NSColor(
            red: 0.0774,
            green: 0.0858,
            blue: 0.1026,
            alpha: 1.0
        )

        // Inset traffic lights from their default positions
        positionTrafficLights(in: window)

        // Re-position traffic lights after layout changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
    }

    @objc private func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        positionTrafficLights(in: window)
    }

    private func positionTrafficLights(in window: NSWindow) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let spacing: CGFloat = 20 // horizontal spacing between traffic light centers

        for (index, buttonType) in buttons.enumerated() {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            button.setFrameOrigin(NSPoint(
                x: Self.trafficLightInset.x + CGFloat(index) * spacing,
                y: window.contentView!.frame.height - button.frame.height - Self.trafficLightInset.y
            ))
        }
    }
}
