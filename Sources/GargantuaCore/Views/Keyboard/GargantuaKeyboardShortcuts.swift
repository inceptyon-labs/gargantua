import AppKit
import SwiftUI

// MARK: - First-responder probe

/// Whether an editable text field currently holds keyboard focus. Used as a
/// last-line safety gate so a destructive menu shortcut (⌘⌫) can never fire
/// while the user is typing in a filter/search field — even on surfaces that
/// don't publish an accurate `isEditingText` flag. AppKit first-responder state
/// isn't SwiftUI-observable, so this is checked at action-fire time, not in
/// `.disabled` (which only re-evaluates when the focused value changes).
enum KeyboardFocusProbe {
    @MainActor
    static func isEditingText() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isFieldEditor || textView.isEditable }
        return responder is NSText
    }
}

// MARK: - Focused action bus

/// The set of actions a results surface (Deep Clean, Duplicates, File Health,
/// Uninstaller, …) exposes to the menu bar. A view publishes the subset it
/// supports via `.focusedSceneValue(\.resultsActions, …)`; the menu commands
/// read it back and disable any item whose closure is `nil`.
///
/// Every field is optional so a surface only lights up the verbs it actually
/// has. `isEditingText` lets a surface temporarily surrender the text-editing
/// chords (⌘A, ⌘I, ⌘F) to a focused field so typing a filter still behaves.
public struct ResultsKeyboardActions {
    public var selectAll: (() -> Void)?
    public var deselectAll: (() -> Void)?
    public var invertSelection: (() -> Void)?
    public var expandAll: (() -> Void)?
    public var collapseAll: (() -> Void)?
    public var cleanSelected: (() -> Void)?
    public var moveToTrash: (() -> Void)?
    public var deletePermanently: (() -> Void)?
    public var revealInFinder: (() -> Void)?
    public var rescan: (() -> Void)?
    public var cancel: (() -> Void)?
    public var focusFilter: (() -> Void)?
    /// True while a text field on the surface holds focus — suppresses the
    /// chords that overlap native text editing so they fall through to the field.
    public var isEditingText: Bool

    public init(
        selectAll: (() -> Void)? = nil,
        deselectAll: (() -> Void)? = nil,
        invertSelection: (() -> Void)? = nil,
        expandAll: (() -> Void)? = nil,
        collapseAll: (() -> Void)? = nil,
        cleanSelected: (() -> Void)? = nil,
        moveToTrash: (() -> Void)? = nil,
        deletePermanently: (() -> Void)? = nil,
        revealInFinder: (() -> Void)? = nil,
        rescan: (() -> Void)? = nil,
        cancel: (() -> Void)? = nil,
        focusFilter: (() -> Void)? = nil,
        isEditingText: Bool = false
    ) {
        self.selectAll = selectAll
        self.deselectAll = deselectAll
        self.invertSelection = invertSelection
        self.expandAll = expandAll
        self.collapseAll = collapseAll
        self.cleanSelected = cleanSelected
        self.moveToTrash = moveToTrash
        self.deletePermanently = deletePermanently
        self.revealInFinder = revealInFinder
        self.rescan = rescan
        self.cancel = cancel
        self.focusFilter = focusFilter
        self.isEditingText = isEditingText
    }
}

public struct ResultsKeyboardActionsKey: FocusedValueKey {
    public typealias Value = ResultsKeyboardActions
}

public struct KeyboardCheatSheetKey: FocusedValueKey {
    public typealias Value = Binding<Bool>
}

public extension FocusedValues {
    var resultsActions: ResultsKeyboardActions? {
        get { self[ResultsKeyboardActionsKey.self] }
        set { self[ResultsKeyboardActionsKey.self] = newValue }
    }

    var keyboardCheatSheet: Binding<Bool>? {
        get { self[KeyboardCheatSheetKey.self] }
        set { self[KeyboardCheatSheetKey.self] = newValue }
    }
}

// MARK: - Menu-bar commands

/// App-level menu commands that drive the focused results surface. Attached once
/// to the main `WindowGroup` in `GargantuaApp`. Items disable themselves when the
/// active surface doesn't publish the matching action, so the menu always
/// reflects what's possible right now — and gives every shortcut a discoverable
/// home (the whole reason these requests kept coming in).
public struct GargantuaResultsCommands: Commands {
    @FocusedValue(\.resultsActions) private var actions
    @FocusedValue(\.keyboardCheatSheet) private var cheatSheet

    public init() {}

    public var body: some Commands {
        // Edit menu: selection verbs, after the standard Cut/Copy/Paste block.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Select All Safe") { actions?.selectAll?() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(actions?.selectAll == nil || actions?.isEditingText == true)
            Button("Deselect All") { actions?.deselectAll?() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(actions?.deselectAll == nil)
            Button("Invert Selection") { actions?.invertSelection?() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(actions?.invertSelection == nil || actions?.isEditingText == true)
        }

        // A dedicated Results menu for tree + action verbs.
        CommandMenu("Results") {
            Button("Expand All Groups") { actions?.expandAll?() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(actions?.expandAll == nil)
            Button("Collapse All Groups") { actions?.collapseAll?() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(actions?.collapseAll == nil)

            Divider()

            Button("Filter Results…") { actions?.focusFilter?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions?.focusFilter == nil)
            Button("Reveal in Finder") { actions?.revealInFinder?() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.revealInFinder == nil)

            Divider()

            Button("Clean Selected…") { actions?.cleanSelected?() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(actions?.cleanSelected == nil)
            // ⌘⌫ / ⇧⌘⌫ overlap text-editing chords (delete-to-line-start). Gate
            // on the published flag AND a live first-responder probe so they can
            // never trash while a filter/search field is focused, even on
            // surfaces that don't wire `isEditingText`.
            Button("Move to Trash") {
                guard !KeyboardFocusProbe.isEditingText() else { return }
                actions?.moveToTrash?()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(actions?.moveToTrash == nil || actions?.isEditingText == true)
            Button("Delete Permanently…") {
                guard !KeyboardFocusProbe.isEditingText() else { return }
                actions?.deletePermanently?()
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .disabled(actions?.deletePermanently == nil || actions?.isEditingText == true)

            Divider()

            Button("Rescan") { actions?.rescan?() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions?.rescan == nil)
            Button("Cancel") { actions?.cancel?() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(actions?.cancel == nil)
        }

        // Help menu: the in-app cheat sheet, always available.
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") {
                cheatSheet?.wrappedValue = true
            }
            .keyboardShortcut("/", modifiers: .command)
            .disabled(cheatSheet == nil)
        }
    }
}

// MARK: - Cheat sheet overlay

/// A static reference card for every shortcut, toggled with ⌘/. Lives as an
/// overlay on the main content so it reads in-context without diving into the
/// menu bar. The single source of truth for "what can I press here".
public struct KeyboardShortcutsCheatSheet: View {
    @Binding var isPresented: Bool

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    private struct Shortcut: Identifiable {
        let id = UUID()
        let keys: String
        let action: String
    }

    private struct Section: Identifiable {
        let id = UUID()
        let title: String
        let shortcuts: [Shortcut]
    }

    private let sections: [Section] = [
        Section(title: "Selection", shortcuts: [
            Shortcut(keys: "⌘A", action: "Select all safe items"),
            Shortcut(keys: "⇧⌘A", action: "Deselect all"),
            Shortcut(keys: "⌘I", action: "Invert selection"),
            Shortcut(keys: "Space", action: "Toggle the focused item"),
        ]),
        Section(title: "Navigation", shortcuts: [
            Shortcut(keys: "↑ ↓", action: "Move between items"),
            Shortcut(keys: "⌃⌘→", action: "Expand all groups"),
            Shortcut(keys: "⌃⌘←", action: "Collapse all groups"),
            Shortcut(keys: "⌘F", action: "Filter results"),
        ]),
        Section(title: "Actions", shortcuts: [
            Shortcut(keys: "⌘↩", action: "Clean selected"),
            Shortcut(keys: "⌘⌫", action: "Move to Trash"),
            Shortcut(keys: "⇧⌘⌫", action: "Delete permanently"),
            Shortcut(keys: "⇧⌘R", action: "Reveal in Finder"),
            Shortcut(keys: "⌘R", action: "Rescan"),
            Shortcut(keys: "⌘.", action: "Cancel the running scan or clean"),
            Shortcut(keys: "Esc", action: "Clear focus, then go back"),
        ]),
        Section(title: "App", shortcuts: [
            Shortcut(keys: "⌘1–9, ⌘0, ⌥⌘1–6", action: "Jump to a sidebar tool"),
            Shortcut(keys: "⌘,", action: "Open Settings"),
            Shortcut(keys: "⌃⌘1–6", action: "Switch Settings tab"),
            Shortcut(keys: "⌥⌘S", action: "Toggle the sidebar"),
            Shortcut(keys: "⌘/", action: "Show this card"),
        ]),
    ]

    public var body: some View {
        ZStack {
            GargantuaColors.scrim
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
                HStack {
                    Text("KEYBOARD SHORTCUTS")
                        .font(GargantuaFonts.sectionLabel)
                        .tracking(0.8)
                        .foregroundStyle(GargantuaColors.ink4)
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(GargantuaColors.ink3)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
                }

                LazyVGrid(
                    columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)],
                    alignment: .leading,
                    spacing: GargantuaSpacing.space5
                ) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                            Text(section.title.uppercased())
                                .font(GargantuaFonts.caption)
                                .tracking(0.6)
                                .foregroundStyle(GargantuaColors.ink3)
                            ForEach(section.shortcuts) { shortcut in
                                HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space3) {
                                    Text(shortcut.keys)
                                        .font(GargantuaFonts.monoData)
                                        .foregroundStyle(GargantuaColors.ink)
                                        .frame(width: 92, alignment: .leading)
                                    Text(shortcut.action)
                                        .font(GargantuaFonts.caption)
                                        .foregroundStyle(GargantuaColors.ink2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            .padding(GargantuaSpacing.space5)
            .frame(maxWidth: 560)
            .background(
                RoundedRectangle(cornerRadius: GargantuaRadius.large, style: .continuous)
                    .fill(GargantuaColors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.large, style: .continuous)
                    .stroke(GargantuaColors.border, lineWidth: 1)
            )
            .padding(GargantuaSpacing.space5)
        }
    }
}
