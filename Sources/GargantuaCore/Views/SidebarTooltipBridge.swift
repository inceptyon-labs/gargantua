import SwiftUI
#if os(macOS)
    import AppKit
#endif

#if os(macOS)
    /// AppKit-bridged tooltip. SwiftUI's `.help()` modifier is unreliable on
    /// macOS — particularly on `Button`s inside `VStack`s with overlay/background
    /// modifiers. This bridges directly to `NSView.toolTip` via an overlay
    /// `NSView` that ignores hit testing so clicks still pass through to the
    /// underlying SwiftUI control.
    private final class PassThroughToolTipNSView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private struct ToolTipBridge: NSViewRepresentable {
        let text: String

        func makeNSView(context: Context) -> PassThroughToolTipNSView {
            let view = PassThroughToolTipNSView()
            view.toolTip = text
            return view
        }

        func updateNSView(_ nsView: PassThroughToolTipNSView, context: Context) {
            nsView.toolTip = text
        }
    }

    extension View {
        @ViewBuilder
        func nativeToolTip(_ text: String, isEnabled: Bool = true) -> some View {
            if isEnabled {
                overlay(ToolTipBridge(text: text))
            } else {
                self
            }
        }
    }
#else
    extension View {
        func nativeToolTip(_ text: String, isEnabled: Bool = true) -> some View {
            self
        }
    }
#endif
