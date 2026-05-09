import AppKit
import SwiftUI

enum PersonalScopeNotice: Equatable {
    enum Tone: Equatable {
        case success
        case review
        case protected
    }

    case added(String)
    case duplicate(String)
    case removed(String)
    case empty
    case invalid(String)
    case failed(String)

    var message: String {
        switch self {
        case .added(let pattern):
            return "Added \(pattern) to personal scope."
        case .duplicate(let pattern):
            return "\(pattern) is already in personal scope."
        case .removed(let pattern):
            return "Removed \(pattern) from personal scope."
        case .empty:
            return "Enter a folder path before adding it."
        case .invalid(let pattern):
            return "\(pattern) is not a valid folder path. Use ~/Folder or an absolute path; / and $HOME are rejected."
        case .failed(let message):
            return message
        }
    }

    var tone: Tone {
        switch self {
        case .added, .removed:
            return .success
        case .duplicate, .empty, .invalid:
            return .review
        case .failed:
            return .protected
        }
    }
}

@MainActor
final class PersonalScopeSettingsViewModel: ObservableObject {
    @Published private(set) var entries: [PersistedPersonalScopeRoot] = []
    @Published var newPattern = ""
    @Published private(set) var notice: PersonalScopeNotice?

    private let persistence: PersistenceController

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    var canAdd: Bool {
        !normalizedPattern.isEmpty
    }

    func load() {
        do {
            try persistence.seedDefaultPersonalScopeRootsIfEmpty()
            entries = try persistence.fetchPersonalScopeRoots()
        } catch {
            entries = []
            notice = .failed("Personal-scope roots could not be loaded.")
        }
    }

    func addDraftPattern() {
        addRaw(normalizedPattern, fromPicker: false)
    }

    func addPickedPath(_ path: String) {
        addRaw(path.trimmingCharacters(in: .whitespacesAndNewlines), fromPicker: true)
    }

    private func addRaw(_ raw: String, fromPicker: Bool) {
        guard !raw.isEmpty else {
            notice = .empty
            return
        }
        guard let pattern = DuplicateFinderScopeFilter.normalize(raw) else {
            notice = .invalid(raw)
            return
        }

        do {
            if try persistence.addPersonalScopeRoot(path: pattern) == nil {
                notice = .duplicate(pattern)
            } else {
                if !fromPicker { newPattern = "" }
                notice = .added(pattern)
                postChangeNotification()
            }
            entries = try persistence.fetchPersonalScopeRoots()
        } catch {
            notice = .failed("Personal-scope root could not be saved.")
            load()
        }
    }

    func removeEntry(pattern: String) {
        do {
            try persistence.removePersonalScopeRoot(path: pattern)
            entries = try persistence.fetchPersonalScopeRoots()
            notice = .removed(pattern)
            postChangeNotification()
        } catch {
            notice = .failed("Personal-scope root could not be removed.")
            load()
        }
    }

    private var normalizedPattern: String {
        newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func postChangeNotification() {
        NotificationCenter.default.post(
            name: .gargantuaPersonalScopeRootsChanged,
            object: nil
        )
    }
}

struct PersonalScopeSettingsSection: View {
    @StateObject private var model: PersonalScopeSettingsViewModel
    @State private var pendingRemoval: PendingPersonalScopeRemoval?

    private let title: String
    private let subtitle: String

    private struct PendingPersonalScopeRemoval: Identifiable {
        let pattern: String
        var id: String { pattern }
    }

    @MainActor
    init(
        persistence: PersistenceController,
        title: String = "Personal scope",
        subtitle: String = "Folders Duplicate Finder treats as personal. Groups whose every file lives inside one of these are shown; everything else is hidden as managed noise."
    ) {
        self._model = StateObject(wrappedValue: PersonalScopeSettingsViewModel(persistence: persistence))
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        SettingsSectionContainer(title, subtitle: subtitle, count: model.entries.count) {
            addRow

            if let notice = model.notice {
                SettingsNoticeRow(
                    icon: noticeSystemImage(notice),
                    message: notice.message,
                    tone: noticeTone(notice)
                )
            }

            if model.entries.isEmpty {
                emptyState
            } else {
                VStack(spacing: 1) {
                    ForEach(model.entries, id: \.pattern) { entry in
                        PersonalScopeEntryRow(
                            entry: entry,
                            onRemove: { pendingRemoval = PendingPersonalScopeRemoval(pattern: entry.pattern) }
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
        }
        .task {
            model.load()
        }
        .sheet(item: $pendingRemoval) { pending in
            DestructiveConfirmSheet(
                title: "Remove this folder?",
                message: "Duplicate Finder will stop showing groups that live in \(pending.pattern). You can re-add it any time.",
                confirmLabel: "Remove folder",
                onCancel: { pendingRemoval = nil },
                onConfirm: {
                    let pattern = pending.pattern
                    pendingRemoval = nil
                    model.removeEntry(pattern: pattern)
                }
            )
        }
    }

    private var addRow: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            SettingsRowIcon(systemName: "folder.badge.plus", color: GargantuaColors.accent, size: 16)

            TextField("Folder path, e.g. ~/Documents or /Volumes/Photos", text: $model.newPattern)
                .textFieldStyle(.plain)
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink)
                .padding(GargantuaSpacing.space2)
                .background(GargantuaColors.surface3)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .onSubmit { model.addDraftPattern() }

            GargantuaButton(
                "Add",
                icon: "plus.circle.fill",
                tone: .ghost(GargantuaColors.accent),
                isDisabled: !model.canAdd,
                action: model.addDraftPattern
            )
            .help("Add personal-scope folder")

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

    private var emptyState: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "folder", color: GargantuaColors.ink4, size: 16)

            SettingsRowText(
                title: "No personal-scope folders",
                detail: "Duplicate Finder will fall back to ~/Documents, ~/Downloads, ~/Desktop, ~/Pictures, ~/Movies, and ~/Music until you add one."
            )
        }
        .padding(GargantuaSpacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GargantuaColors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(GargantuaColors.borderSoft, lineWidth: 1)
        )
    }

    private func noticeSystemImage(_ notice: PersonalScopeNotice) -> String {
        switch notice.tone {
        case .success: return "checkmark.circle.fill"
        case .review: return "exclamationmark.triangle.fill"
        case .protected: return "xmark.octagon.fill"
        }
    }

    private func noticeTone(_ notice: PersonalScopeNotice) -> SettingsNoticeRow.Tone {
        switch notice.tone {
        case .success: return .safe
        case .review: return .review
        case .protected: return .protected
        }
    }
}

private struct PersonalScopeEntryRow: View {
    let entry: PersistedPersonalScopeRoot
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 16, alignment: .center)

            Text(entry.pattern)
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink)
                .lineLimit(1)
                .textSelection(.enabled)

            Spacer(minLength: GargantuaSpacing.space3)

            Text(entry.createdAt, style: .date)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink4)

            SettingsRemoveButton(help: "Remove personal-scope folder", action: onRemove)
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(isHovered ? GargantuaColors.surface3 : GargantuaColors.surface1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
