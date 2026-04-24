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
            return "Added \(pattern) to the whitelist."
        case .duplicate(let pattern):
            return "\(pattern) is already whitelisted."
        case .removed(let pattern):
            return "Removed \(pattern) from the whitelist."
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
            entries = try persistence.fetchWhitelistEntries()
        } catch {
            entries = []
            notice = .failed("Whitelist entries could not be loaded.")
        }
    }

    func addDraftPattern() {
        let pattern = normalizedPattern
        guard !pattern.isEmpty else {
            notice = .empty
            return
        }

        do {
            if try persistence.addWhitelistEntry(pattern: pattern) == nil {
                notice = .duplicate(pattern)
            } else {
                newPattern = ""
                notice = .added(pattern)
            }
            entries = try persistence.fetchWhitelistEntries()
        } catch {
            notice = .failed("Whitelist entry could not be saved.")
            load()
        }
    }

    func removeEntry(pattern: String) {
        do {
            try persistence.removeWhitelistEntry(pattern: pattern)
            entries = try persistence.fetchWhitelistEntries()
            notice = .removed(pattern)
        } catch {
            notice = .failed("Whitelist entry could not be removed.")
            load()
        }
    }

    private var normalizedPattern: String {
        newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PathExclusionSettingsSection: View {
    @StateObject private var model: PathExclusionSettingsViewModel

    private let title: String
    private let subtitle: String
    private let showsDivider: Bool
    private let titleFont: Font

    @MainActor
    init(
        persistence: PersistenceController,
        title: String = "Whitelists",
        subtitle: String = "Paths and glob patterns excluded from cleanup scans.",
        showsDivider: Bool = false,
        titleFont: Font = GargantuaFonts.label
    ) {
        self._model = StateObject(wrappedValue: PathExclusionSettingsViewModel(persistence: persistence))
        self.title = title
        self.subtitle = subtitle
        self.showsDivider = showsDivider
        self.titleFont = titleFont
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            if showsDivider {
                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)
            }

            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                HStack(spacing: GargantuaSpacing.space2) {
                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(GargantuaColors.ink2)

                    Text("\(model.entries.count)")
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink4)
                }

                Text(subtitle)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }

            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                addRow

                if let notice = model.notice {
                    noticeRow(notice)
                }

                if model.entries.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 1) {
                        ForEach(model.entries, id: \.pattern) { entry in
                            PathExclusionEntryRow(
                                entry: entry,
                                onRemove: { model.removeEntry(pattern: entry.pattern) }
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
                }
            }
            .padding(GargantuaSpacing.space4)
            .background(GargantuaColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
        .task {
            model.load()
        }
    }

    private var addRow: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "shield.slash")
                .font(.system(size: 16))
                .foregroundStyle(GargantuaColors.accent)
                .frame(width: 24, alignment: .center)

            TextField("Path or pattern, e.g. ~/Library/Caches/MyApp", text: $model.newPattern)
                .textFieldStyle(.plain)
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink)
                .padding(GargantuaSpacing.space2)
                .background(GargantuaColors.surface3)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .onSubmit { model.addDraftPattern() }

            Button(action: model.addDraftPattern) {
                Label("Add", systemImage: "plus.circle.fill")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(model.canAdd ? GargantuaColors.accent : GargantuaColors.ink4)
                    .padding(.horizontal, GargantuaSpacing.space3)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .background((model.canAdd ? GargantuaColors.accent : GargantuaColors.ink4).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .disabled(!model.canAdd)
            .help("Add whitelist entry")
        }
    }

    private func noticeRow(_ notice: PathExclusionNotice) -> some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
            Image(systemName: noticeSystemImage(notice))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(noticeColor(notice))
                .frame(width: 16, alignment: .center)

            Text(notice.message)
                .font(GargantuaFonts.caption)
                .foregroundStyle(noticeColor(notice))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(GargantuaSpacing.space3)
        .background(noticeColor(notice).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            Image(systemName: "shield")
                .font(.system(size: 16))
                .foregroundStyle(GargantuaColors.ink4)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                Text("No whitelist entries")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink2)

                Text("Add exact paths or glob patterns for files Gargantua should leave untouched.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(GargantuaSpacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GargantuaColors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
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

    private func noticeColor(_ notice: PathExclusionNotice) -> Color {
        switch notice.tone {
        case .success: return GargantuaColors.safe
        case .review: return GargantuaColors.review
        case .protected: return GargantuaColors.protected_
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

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(isHovered ? GargantuaColors.protected_ : GargantuaColors.ink4)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Remove whitelist entry")
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(isHovered ? GargantuaColors.surface3 : GargantuaColors.surface1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
