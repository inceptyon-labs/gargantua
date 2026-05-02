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
        let path = normalizedNewPath
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
            newPath = ""
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

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                HStack(spacing: GargantuaSpacing.space2) {
                    Text("Protected Roots")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink2)

                    Text("\(model.bundledEntries.count + model.userEntries.count)")
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink4)
                }

                Text("Global cleanup-deny policy. These paths can never be removed as whole cleanup units.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                addRow

                if let notice = model.notice {
                    noticeRow(notice)
                }

                if !model.userEntries.isEmpty {
                    entryGroup(title: "User Added", entries: model.userEntries, isBundled: false)
                }

                entryGroup(title: "Bundled Policy", entries: model.bundledEntries, isBundled: true)
            }
            .padding(GargantuaSpacing.space4)
            .background(GargantuaColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
        .task { model.load() }
    }

    private var addRow: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(GargantuaColors.protected_)
                .frame(width: 24, alignment: .center)

            TextField("Protect root, e.g. ~/Important or /Volumes/Archive", text: $model.newPath)
                .textFieldStyle(.plain)
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink)
                .padding(GargantuaSpacing.space2)
                .background(GargantuaColors.surface3)
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                .onSubmit { model.addDraftPath() }

            Button(action: model.addDraftPath) {
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
            .help("Add user protected root")
        }
    }

    private func entryGroup(title: String, entries: [ProtectedRootEntry], isBundled: Bool) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            HStack {
                Text(title.uppercased())
                    .font(GargantuaFonts.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(GargantuaColors.ink3)

                Spacer()

                Text("\(entries.count)")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink4)
            }

            VStack(spacing: 1) {
                ForEach(entries) { entry in
                    ProtectedRootEntryRow(
                        entry: entry,
                        isBundled: isBundled,
                        onRemove: { model.removeUserEntry(path: entry.path) }
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
    }

    private func noticeRow(_ notice: ProtectedRootNotice) -> some View {
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

    private func noticeSystemImage(_ notice: ProtectedRootNotice) -> String {
        switch notice.tone {
        case .success: return "checkmark.circle.fill"
        case .review: return "exclamationmark.triangle.fill"
        case .protected: return "xmark.octagon.fill"
        }
    }

    private func noticeColor(_ notice: ProtectedRootNotice) -> Color {
        switch notice.tone {
        case .success: return GargantuaColors.safe
        case .review: return GargantuaColors.review
        case .protected: return GargantuaColors.protected_
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
                .foregroundStyle(isBundled ? GargantuaColors.ink3 : GargantuaColors.accent)
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
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(isHovered ? GargantuaColors.protected_ : GargantuaColors.ink4)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Remove protected root")
            }
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(isHovered ? GargantuaColors.surface3 : GargantuaColors.surface1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
