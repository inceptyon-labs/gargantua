import SwiftUI

/// All known scan categories, ordered by area (system → dev → browser → advanced).
public enum ScanCategory: String, CaseIterable, Identifiable {
    case systemCache = "system_cache"
    case systemLogs = "system_logs"
    case tempFiles = "temp_files"
    case trash
    case installers
    case devArtifacts = "dev_artifacts"
    case docker
    case homebrew
    case browserCache = "browser_cache"
    case browserData = "browser_data"
    case similarImages = "similar_images"
    case emptyFiles = "empty_files"
    case brokenSymlinks = "broken_symlinks"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .systemCache: return "System Caches"
        case .systemLogs: return "System Logs"
        case .tempFiles: return "Temp Files"
        case .trash: return "Trash"
        case .installers: return "Installers"
        case .devArtifacts: return "Dev Artifacts"
        case .docker: return "Docker"
        case .homebrew: return "Homebrew"
        case .browserCache: return "Browser Cache"
        case .browserData: return "Browser Data"
        case .similarImages: return "Similar Images"
        case .emptyFiles: return "Empty Files"
        case .brokenSymlinks: return "Broken Symlinks"
        }
    }

    public var icon: String {
        switch self {
        case .systemCache: return "memorychip"
        case .systemLogs: return "doc.text"
        case .tempFiles: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .trash: return "trash"
        case .installers: return "arrow.down.circle"
        case .devArtifacts: return "hammer"
        case .docker: return "shippingbox"
        case .homebrew: return "mug"
        case .browserCache: return "globe"
        case .browserData: return "globe.badge.chevron.backward"
        case .similarImages: return "photo.on.rectangle"
        case .emptyFiles: return "doc"
        case .brokenSymlinks: return "link"
        }
    }
}

// MARK: - Profile List View

/// Displays all cleanup profiles with active indicator and edit capability.
///
/// Built-in profiles (Developer, Light, Deep) can be edited (toggle categories)
/// but not deleted or renamed. Custom profiles support full CRUD.
public struct ProfileListView: View {
    let profiles: [CleanupProfile]
    let activeProfileID: String
    let onSetActive: (String) -> Void
    let onEdit: (CleanupProfile) -> Void
    let onCreateCustom: () -> Void
    let onDelete: (String) -> Void

    public init(
        profiles: [CleanupProfile],
        activeProfileID: String,
        onSetActive: @escaping (String) -> Void,
        onEdit: @escaping (CleanupProfile) -> Void,
        onCreateCustom: @escaping () -> Void,
        onDelete: @escaping (String) -> Void
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.onSetActive = onSetActive
        self.onEdit = onEdit
        self.onCreateCustom = onCreateCustom
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Profiles")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Spacer()

                Button(action: onCreateCustom) {
                    HStack(spacing: GargantuaSpacing.space1) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                        Text("Custom")
                            .font(GargantuaFonts.caption)
                    }
                    .foregroundStyle(GargantuaColors.accent)
                    .padding(.horizontal, GargantuaSpacing.space3)
                    .padding(.vertical, GargantuaSpacing.space1)
                    .background(GargantuaColors.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, GargantuaSpacing.space6)
            .padding(.top, GargantuaSpacing.space6)
            .padding(.bottom, GargantuaSpacing.space5)

            // Profile cards
            ScrollView {
                VStack(spacing: GargantuaSpacing.space3) {
                    ForEach(profiles) { profile in
                        ProfileCardView(
                            profile: profile,
                            isActive: profile.id == activeProfileID,
                            onSetActive: { onSetActive(profile.id) },
                            onEdit: { onEdit(profile) },
                            onDelete: profile.isCustom ? { onDelete(profile.id) } : nil
                        )
                    }
                }
                .padding(.horizontal, GargantuaSpacing.space6)
                .padding(.bottom, GargantuaSpacing.space6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GargantuaColors.void_)
    }
}

// MARK: - Profile Card

private struct ProfileCardView: View {
    let profile: CleanupProfile
    let isActive: Bool
    let onSetActive: () -> Void
    let onEdit: () -> Void
    let onDelete: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: GargantuaSpacing.space4) {
            // Active indicator bar
            Rectangle()
                .fill(isActive ? GargantuaColors.accent : Color.clear)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                HStack {
                    Text(profile.name)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)

                    if isActive {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(GargantuaColors.accent)
                            .tracking(0.5)
                    }

                    if profile.isCustom {
                        Text("CUSTOM")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(GargantuaColors.ink3)
                            .tracking(0.5)
                    }

                    Spacer()

                    if isHovered || isActive {
                        HStack(spacing: GargantuaSpacing.space2) {
                            if !isActive {
                                Button(action: onSetActive) {
                                    Text("Set Active")
                                        .font(GargantuaFonts.caption)
                                        .foregroundStyle(GargantuaColors.accent)
                                }
                                .buttonStyle(.plain)
                            }

                            Button(action: onEdit) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 12))
                                    .foregroundStyle(GargantuaColors.ink2)
                            }
                            .buttonStyle(.plain)

                            if let onDelete {
                                Button(action: onDelete) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12))
                                        .foregroundStyle(GargantuaColors.protected_)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Text(profile.description)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .lineLimit(2)

                // Category pills
                FlowLayout(spacing: GargantuaSpacing.space1) {
                    ForEach(profile.categories, id: \.self) { categoryID in
                        if let category = ScanCategory(rawValue: categoryID) {
                            CategoryPill(category: category)
                        }
                    }
                }
                .padding(.top, GargantuaSpacing.space1)
            }
            .padding(.vertical, GargantuaSpacing.space3)
            .padding(.trailing, GargantuaSpacing.space4)
        }
        .background(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .fill(isActive ? GargantuaColors.accent.opacity(0.06) : GargantuaColors.surface2)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Category Pill

private struct CategoryPill: View {
    let category: ScanCategory

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: category.icon)
                .font(.system(size: 9))
            Text(category.displayName)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(GargantuaColors.ink3)
        .padding(.horizontal, GargantuaSpacing.space2)
        .padding(.vertical, 3)
        .background(GargantuaColors.surface3)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }
}

// MARK: - Flow Layout

/// Simple horizontal wrapping layout for category pills.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight
            if index < rows.count - 1 { height += spacing }
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
    }
}
