import AppKit
import SwiftUI

extension OrganizerStagedPreviewView {

    // MARK: - Idle composition

    var idleState: some View {
        ScrollView {
            VStack(spacing: GargantuaSpacing.space5) {
                idleHeader
                OrganizerEngineSelector(mlxAvailabilityProvider: mlxAvailabilityProvider)
                folderPicker
                proposeButton
                trustReassurance
            }
            .padding(GargantuaSpacing.space6)
            .frame(maxWidth: .infinity)
        }
    }

    private var idleHeader: some View {
        VStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 44))
                .foregroundStyle(GargantuaColors.accent)
            Text("File Organizer")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)
            Text(
                "Pick an engine and a folder. The proposal is reviewed before anything moves — " +
                "nothing is touched until you click Apply."
            )
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }

    private var proposeButton: some View {
        Button("Propose groupings for \(session.selectedTarget.displayName)") {
            session.startScan()
        }
        .font(GargantuaFonts.label)
        .foregroundStyle(.white)
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.accent)
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        .buttonStyle(.plain)
    }

    // MARK: - Folder picker

    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Text("CHOOSE A FOLDER")
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink4)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130), spacing: GargantuaSpacing.space2, alignment: .leading)],
                alignment: .leading,
                spacing: GargantuaSpacing.space2
            ) {
                ForEach(allTargets) { target in
                    folderChip(target)
                }
                addFolderChip
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var allTargets: [OrganizerTarget] {
        OrganizerTarget.builtIns + customFolders.map { OrganizerTarget.custom($0) }
    }

    @ViewBuilder
    private func folderChip(_ target: OrganizerTarget) -> some View {
        let isSelected = session.selectedTarget == target
        HStack(spacing: GargantuaSpacing.space1) {
            Image(systemName: target.systemImage)
                .font(.system(size: 12))
            Text(target.displayName)
                .font(GargantuaFonts.label)
                .lineLimit(1)
            if case .custom(let url) = target {
                Button {
                    folderStore.remove(url)
                    customFolders = folderStore.load()
                    if session.selectedTarget == target {
                        session.selectedTarget = .downloads
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(GargantuaColors.ink4)
                }
                .buttonStyle(.plain)
                .help("Remove this folder from your list")
            }
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(isSelected ? GargantuaColors.accent.opacity(0.18) : GargantuaColors.surface2)
        .foregroundStyle(isSelected ? GargantuaColors.accent : GargantuaColors.ink2)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(
                    isSelected ? GargantuaColors.accent : GargantuaColors.borderSoft,
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        .contentShape(Rectangle())
        .onTapGesture { session.selectedTarget = target }
    }

    private var addFolderChip: some View {
        Button(action: pickCustomFolder) {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12))
                Text("Add folder…")
                    .font(GargantuaFonts.label)
            }
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .foregroundStyle(GargantuaColors.ink3)
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .strokeBorder(
                        GargantuaColors.borderSoft,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func pickCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        panel.message = "Pick a folder for the organizer to scan."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderStore.add(url)
        customFolders = folderStore.load()
        session.selectedTarget = .custom(url)
    }

    // MARK: - Trust signals

    var trustReassurance: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 14))
                .foregroundStyle(GargantuaColors.safe)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reversible")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                Text(
                    "Every move is recorded. One click undoes the whole batch — " +
                    "files return to their original locations, the new subfolders are cleared away."
                )
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
            }
        }
        .padding(GargantuaSpacing.space3)
        .frame(maxWidth: 460, alignment: .leading)
        .background(GargantuaColors.surface1)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.borderSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
    }
}
