import SwiftUI

enum PathExclusionNotice: Equatable {
    enum Tone: Equatable {
        case success
        case review
        case protected
    }

    case added(String)
    case duplicate(String)
    case removed(String)
    case empty
    case failed(String)

    var message: String {
        switch self {
        case .added(let pattern):
            return "Added \(pattern) to exclusions."
        case .duplicate(let pattern):
            return "\(pattern) is already excluded."
        case .removed(let pattern):
            return "Removed \(pattern) from exclusions."
        case .empty:
            return "Enter a path or glob pattern before adding it."
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
final class PathExclusionSettingsViewModel: ObservableObject {
    @Published private(set) var entries: [PersistedWhitelistEntry] = []
    @Published var newPattern = ""
    @Published private(set) var notice: PathExclusionNotice?

    private let persistence: PersistenceController

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    var canAdd: Bool {
        !normalizedPattern.isEmpty
    }

    func load() {
        do {
            entries = try persistence.fetchExclusionEntries()
        } catch {
            entries = []
            notice = .failed("Exclusion entries could not be loaded.")
        }
    }

    func addDraftPattern() {
        let pattern = normalizedPattern
        guard !pattern.isEmpty else {
            notice = .empty
            return
        }

        do {
            if try persistence.addExclusionEntry(pattern: pattern) == nil {
                notice = .duplicate(pattern)
            } else {
                newPattern = ""
                notice = .added(pattern)
            }
            entries = try persistence.fetchExclusionEntries()
        } catch {
            notice = .failed("Exclusion entry could not be saved.")
            load()
        }
    }

    func removeEntry(pattern: String) {
        do {
            try persistence.removeExclusionEntry(pattern: pattern)
            entries = try persistence.fetchExclusionEntries()
            notice = .removed(pattern)
        } catch {
            notice = .failed("Exclusion entry could not be removed.")
            load()
        }
    }

    private var normalizedPattern: String {
        newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PathExclusionSettingsSection: View {
    @StateObject private var model: PathExclusionSettingsViewModel
    @State private var pendingRemoval: PendingExclusionRemoval?

    private let title: String
    private let subtitle: String

    private struct PendingExclusionRemoval: Identifiable {
        let pattern: String
        var id: String { pattern }
    }

    @MainActor
    init(
        persistence: PersistenceController,
        title: String = "Exclusions",
        subtitle: String = "Paths and glob patterns Gargantua should never propose for cleanup."
    ) {
        self._model = StateObject(wrappedValue: PathExclusionSettingsViewModel(persistence: persistence))
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
                        PathExclusionEntryRow(
                            entry: entry,
                            onRemove: { pendingRemoval = PendingExclusionRemoval(pattern: entry.pattern) }
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
                title: "Remove this exclusion?",
                message: "Future scans may propose cleaning paths matching \(pending.pattern). You can re-add it any time.",
                confirmLabel: "Remove exclusion",
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
            SettingsRowIcon(systemName: "shield.slash", color: GargantuaColors.accent, size: 16)

            TextField("Path or pattern, e.g. ~/Library/Caches/MyApp", text: $model.newPattern)
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
            .help("Add exclusion entry")
        }
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            SettingsRowIcon(systemName: "shield", color: GargantuaColors.ink4, size: 16)

            SettingsRowText(
                title: "No exclusions yet",
                detail: "Add paths or glob patterns Gargantua should always leave untouched."
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

    private func noticeSystemImage(_ notice: PathExclusionNotice) -> String {
        switch notice.tone {
        case .success: return "checkmark.circle.fill"
        case .review: return "exclamationmark.triangle.fill"
        case .protected: return "xmark.octagon.fill"
        }
    }

    private func noticeTone(_ notice: PathExclusionNotice) -> SettingsNoticeRow.Tone {
        switch notice.tone {
        case .success: return .safe
        case .review: return .review
        case .protected: return .protected
        }
    }
}

private struct PathExclusionEntryRow: View {
    let entry: PersistedWhitelistEntry
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "shield.fill")
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

            SettingsRemoveButton(help: "Remove exclusion entry", action: onRemove)
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(isHovered ? GargantuaColors.surface3 : GargantuaColors.surface1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
