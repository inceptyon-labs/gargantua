import SwiftUI

extension ScanBucketListView {
    var filterField: some View {
        HStack(spacing: GargantuaSpacing.space1) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(GargantuaColors.ink4)

            ZStack(alignment: .leading) {
                if naturalLanguageQuery.isEmpty {
                    Text("Search results")
                        .font(GargantuaFonts.body)
                        .foregroundStyle(GargantuaColors.ink2)
                        .allowsHitTesting(false)
                }

                TextField("", text: $naturalLanguageQuery)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .focused($isSearchFocused)
                    .onSubmit(resolveNaturalLanguageFilter)
                    .accessibilityLabel("Search results")
            }
            .frame(minWidth: 260, maxWidth: 460, minHeight: 24)

            if isResolvingFilter {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 16, height: 16)
            } else {
                Button(action: resolveNaturalLanguageFilter) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GargantuaColors.accent)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .disabled(naturalLanguageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(naturalLanguageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                .help("Resolve search")
            }

            if activeFilter != nil || !naturalLanguageQuery.isEmpty || filterStatus != nil {
                Button(action: clearNaturalLanguageFilter) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GargantuaColors.ink4)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, GargantuaSpacing.space2)
        .padding(.vertical, GargantuaSpacing.space1)
        .background(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .fill(isSearchFocused ? GargantuaColors.surface4 : GargantuaColors.surface3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(isSearchFocused ? GargantuaColors.borderFocus : GargantuaColors.borderEm, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            NSApp.activate(ignoringOtherApps: true)
            isSearchFocused = true
        }
    }

    /// Inline filter input revealed when the user taps the refine icon. The
    /// status string surfaces NL-resolution errors and the active match count.
    var refineFieldPanel: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            filterField
            if let filterStatus {
                filterStatusView(filterStatus)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface1)
    }

    private func filterStatusView(_ status: String) -> some View {
        HStack(spacing: GargantuaSpacing.space2) {
            Image(systemName: activeFilter == nil ? "exclamationmark.triangle" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(activeFilter == nil ? GargantuaColors.review : GargantuaColors.accent)
            Text(status)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .lineLimit(1)
        }
    }

    func resolveNaturalLanguageFilter() {
        guard let resolver = onResolveNaturalLanguageFilter else { return }
        let query = naturalLanguageQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isResolvingFilter else { return }

        isResolvingFilter = true
        Task {
            let filter = await resolver(query)
            await MainActor.run {
                isResolvingFilter = false
                if let filter {
                    activeFilter = filter
                    let count = filter.apply(to: results).count
                    filterStatus = "\(count) match\(count == 1 ? "" : "es")"
                } else {
                    activeFilter = nil
                    filterStatus = "Didn't understand"
                }
            }
        }
    }

    func clearNaturalLanguageFilter() {
        naturalLanguageQuery = ""
        activeFilter = nil
        filterStatus = nil
        isResolvingFilter = false
        if hasRefinementTools {
            showsRefineControls = false
        }
    }

    func trimSelectionToDisplayedResults() {
        let visible = Set(displayedResults.map(\.id))
        selectedIDs.formIntersection(visible)
    }
}
