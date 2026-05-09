import AppKit
import SwiftUI

private enum ProtectedRootNotice: Equatable {
    enum Tone { case success, review, protected }

    case added(String)
    case duplicate(String)
    case removed(String)
    case empty
    case failed(String)

    var message: String {
        switch self {
        case .added(let path):
            return "Added \(path) to protected roots."
        case .duplicate(let path):
            return "\(path) is already protected."
        case .removed(let path):
            return "Removed \(path) from protected roots."
        case .empty:
            return "Enter an absolute path, ~/ path, or ${HOME} path before adding it."
        case .failed(let message):
            return message
        }
    }

    var tone: Tone {
        switch self {
        case .added, .removed:
            return .success
        case .duplicate, .empty:
            return .review
        case .failed:
            return .protected
        }
    }
}

@MainActor
private final class ProtectedRootsSettingsViewModel: ObservableObject {
    @Published private(set) var bundledEntries: [ProtectedRootEntry] = []
    @Published private(set) var userEntries: [ProtectedRootEntry] = []
    @Published var newPath = ""
    @Published private(set) var notice: ProtectedRootNotice?

    private let loader: ProtectedRootPolicyLoader
    private let store: ProtectedRootUserStore

    init(
        loader: ProtectedRootPolicyLoader = ProtectedRootPolicyLoader(),
        store: ProtectedRootUserStore = ProtectedRootUserStore()
    ) {
        self.loader = loader
        self.store = store
    }

    var canAdd: Bool {
        Self.isValidPath(normalizedNewPath)
    }

    func load() {
        do {
            bundledEntries = try loader.loadBundled().entries
        } catch {
            bundledEntries = []
            notice = .failed("Bundled protected-root policy could not be loaded.")
        }
        userEntries = store.loadEntries()
    }

    func addDraftPath() {
        addRaw(normalizedNewPath, fromPicker: false)
    }

    func addPickedPath(_ path: String) {
        addRaw(path.trimmingCharacters(in: .whitespacesAndNewlines), fromPicker: true)
    }

    private func addRaw(_ path: String, fromPicker: Bool) {
        guard Self.isValidPath(path) else {
            notice = .empty
            return
        }

        let allPaths = Set((bundledEntries + userEntries).map(\.path))
        guard !allPaths.contains(path) else {
            notice = .duplicate(path)
            return
        }

        if store.add(path: path) {
            if !fromPicker { newPath = "" }
            notice = .added(path)
            userEntries = store.loadEntries()
        } else {
            notice = .failed("Protected root could not be saved.")
        }
    }

    func removeUserEntry(path: String) {
        store.remove(path: path)
        userEntries = store.loadEntries()
        notice = .removed(path)
    }

    private var normalizedNewPath: String {
        newPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValidPath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return path == "~"
            || path.hasPrefix("~/")
            || path.hasPrefix("/")
            || path.hasPrefix("${HOME}")
    }
}

struct ProtectedRootsSettingsSection: View {
    @StateObject private var model = ProtectedRootsSettingsViewModel()
    @State private var pendingRemoval: PendingProtectedRemoval?

    private struct PendingProtectedRemoval: Identifiable {
        let path: String
        var id: String { path }
    }

    var body: some View {
        SettingsSectionContainer(
            "Protected Roots",
            subtitle: "Global cleanup-deny policy. These paths can never be removed as whole cleanup units.",
            count: model.bundledEntries.count + model.userEntries.count
        ) {
            addRow

            if let notice = model.notice {
                SettingsNoticeRow(
                    icon: noticeSystemImage(notice),
                    message: notice.message,
                    tone: noticeTone(notice)
                )
            }

            if !model.userEntries.isEmpty {
                entryGroup(title: "User Added", entries: model.userEntries, isBundled: false)
            }

            entryGroup(title: "Bundled Policy", entries: model.bundledEntries, isBundled: true)
        }
        .task { model.load() }
        .sheet(item: $pendingRemoval) { pending in
            DestructiveConfirmSheet(
                title: "Unprotect this root?",
                message: "Future scans may propose deleting cleanup units inside \(pending.path). You can re-protect it any time.",
                confirmLabel: "Unprotect root",
                onCancel: { pendingRemoval = nil },
                onConfirm: {
                    let path = pending.path
                    pendingRemoval = nil
                    model.removeUserEntry(path: path)
                }
            )
        }
    }

    private var addRow: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            SettingsRowIcon(
                systemName: "lock.shield.fill",
                color: GargantuaColors.protected_,
                size: 16
            )

            TextField("Protect root, e.g. ~/Important or /Volumes/Archive", text: $model.newPath)
                .textFieldStyle(.plain)
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink)
                .padding(GargantuaSpacing.space2)
                .background(GargantuaColors.surface3)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .onSubmit { model.addDraftPath() }

            GargantuaButton(
                "Add",
                icon: "plus.circle.fill",
                tone: .ghost(GargantuaColors.accent),
                isDisabled: !model.canAdd,
                action: model.addDraftPath
            )
            .help("Add user protected root")

            GargantuaIconButton(
                icon: "folder.badge.plus",
                help: "Choose folder from disk",
                color: GargantuaColors.accent,
                action: chooseFolders
            )
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            model.addPickedPath(url.standardizedFileURL.path)
        }
    }

    private func entryGroup(title: String, entries: [ProtectedRootEntry], isBundled: Bool) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            SettingsSubsectionHeader(title, count: entries.count)

            VStack(spacing: 1) {
                ForEach(entries) { entry in
                    ProtectedRootEntryRow(
                        entry: entry,
                        isBundled: isBundled,
                        onRemove: { pendingRemoval = PendingProtectedRemoval(path: entry.path) }
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        }
    }

    private func noticeSystemImage(_ notice: ProtectedRootNotice) -> String {
        switch notice.tone {
        case .success: return "checkmark.circle.fill"
        case .review: return "exclamationmark.triangle.fill"
        case .protected: return "xmark.octagon.fill"
        }
    }

    private func noticeTone(_ notice: ProtectedRootNotice) -> SettingsNoticeRow.Tone {
        switch notice.tone {
        case .success: return .safe
        case .review: return .review
        case .protected: return .protected
        }
    }
}

private struct ProtectedRootEntryRow: View {
    let entry: ProtectedRootEntry
    let isBundled: Bool
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space3) {
            Image(systemName: isBundled ? "checkmark.shield.fill" : "person.badge.shield.checkmark.fill")
                .font(.system(size: 12))
                .foregroundStyle(isBundled ? GargantuaColors.ink3 : GargantuaColors.ink)
                .frame(width: 16, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.path)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink)
                    .lineLimit(1)
                    .textSelection(.enabled)

                Text(entry.reason)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
            }

            Spacer(minLength: GargantuaSpacing.space3)

            if isBundled {
                Text("Bundled")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink4)
            } else {
                SettingsRemoveButton(help: "Unprotect this root", action: onRemove)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(isHovered ? GargantuaColors.surface3 : GargantuaColors.surface1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
