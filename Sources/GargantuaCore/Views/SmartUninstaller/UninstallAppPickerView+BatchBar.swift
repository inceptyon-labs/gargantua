import SwiftUI

extension UninstallAppPickerView {
    var batchActionBar: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Text(viewModel.multiSelected.count == 1
                ? "1 app selected"
                : "\(viewModel.multiSelected.count) apps selected")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)

            // Surface selections the current filter is hiding so the user
            // can't accidentally trash apps that fell off-screen when they
            // typed in search or flipped the system-apps toggle.
            if viewModel.hiddenSelectedCount > 0 {
                hiddenSelectionPill
            }

            Spacer()

            Button {
                viewModel.clearMultiSelect()
            } label: {
                Text("Clear")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink2)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .padding(.horizontal, GargantuaSpacing.space3)
                    .overlay(
                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                            .stroke(GargantuaColors.borderEm, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear app selection")

            Button {
                viewModel.runTracked { await viewModel.startBatchUninstall() }
            } label: {
                Text(viewModel.multiSelected.count == 1
                    ? "Uninstall 1 app"
                    : "Uninstall \(viewModel.multiSelected.count) apps")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(.white)
                    .padding(.vertical, GargantuaSpacing.space2)
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .background(GargantuaColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, GargantuaSpacing.space5)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface1)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)
        }
    }

    var hiddenSelectionPill: some View {
        Button {
            viewModel.clearHiddenSelections()
        } label: {
            Text("Drop \(viewModel.hiddenSelectedCount) not shown")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.review)
                .padding(.vertical, 1)
                .padding(.horizontal, 6)
                .background(GargantuaColors.reviewDim)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help("These apps are selected but hidden by the active filter. Click to drop them.")
        .accessibilityLabel("Drop \(viewModel.hiddenSelectedCount) selections that aren't shown")
    }
}
