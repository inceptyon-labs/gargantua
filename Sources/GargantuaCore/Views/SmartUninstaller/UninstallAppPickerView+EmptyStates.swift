import SwiftUI

extension UninstallAppPickerView {
    @ViewBuilder
    var emptyState: some View {
        if viewModel.apps.isEmpty {
            emptyStateNoApps
        } else if !viewModel.query.isEmpty {
            emptyStateNoMatches
        } else {
            emptyStateAllFiltered
        }
    }

    var emptyStateNoApps: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "questionmark.app.dashed")
                .font(.system(size: 28))
                .foregroundStyle(GargantuaColors.ink4)

            Text("Couldn't find any installed apps")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink2)

            Text("This usually means Gargantua doesn't have permission to read your Applications folder."
                 + " Grant access in System Settings, then rescan.")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            HStack(spacing: GargantuaSpacing.space2) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                    Link(destination: url) {
                        Text("Open System Settings")
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink)
                            .padding(.vertical, GargantuaSpacing.space2)
                            .padding(.horizontal, GargantuaSpacing.space4)
                            .overlay(
                                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                    .stroke(GargantuaColors.borderEm, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    viewModel.runTracked { await viewModel.rescanApps() }
                } label: {
                    Text("Rescan")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(.white)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .background(GargantuaColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, GargantuaSpacing.space1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var emptyStateNoMatches: some View {
        VStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(GargantuaColors.ink4)

            Text("No matches")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink2)

            Text("Search covers app name and bundle identifier. Try a shorter or different term.")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if viewModel.hiddenSystemMatchCount > 0 {
                Button {
                    viewModel.showSystemApps = true
                } label: {
                    Text(viewModel.hiddenSystemMatchCount == 1
                        ? "1 system app matches. Show system apps?"
                        : "\(viewModel.hiddenSystemMatchCount) system apps match. Show system apps?")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, GargantuaSpacing.space2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var emptyStateAllFiltered: some View {
        VStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 28))
                .foregroundStyle(GargantuaColors.ink4)

            Text("Nothing to show")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink2)

            Text("Every installed app is filtered out. Turn on \"Show system apps\" if you're looking for one of those.")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
