import SwiftUI

struct FileHealthSimilarityControls: View {
    let tab: FileHealthCategoryTab
    let filteredCount: Int
    @Binding var filterText: String
    @Binding var clusterSuggestions: [String: [String: FileHealthClusterSuggestion]]
    @Binding var suggestingTabIDs: Set<String>
    @Binding var attemptedSuggestionTabIDs: Set<String>
    let onSuggestClusters: FileHealthView.ClusterSuggestionHandler?

    @Environment(\.activeAIEngineKind) private var activeAIEngineKind

    var body: some View {
        let clusters = FileHealthPathClusterer.clusters(from: tab.findings)
        let trimmedFilter = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filterIsActive = !trimmedFilter.isEmpty
        let tabSuggestions = clusterSuggestions[tab.id] ?? [:]
        let isSuggesting = suggestingTabIDs.contains(tab.id)

        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(GargantuaColors.ink3)

                TextField(
                    "Filter by path",
                    text: $filterText
                )
                .textFieldStyle(.plain)
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink)

                if filterIsActive {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(GargantuaColors.ink3)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                    .accessibilityLabel("Clear filter")
                }

                Spacer()

                if filterIsActive {
                    Text("\(filteredCount) of \(tab.count) visible")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .fill(GargantuaColors.surface3)
            )

            if !clusters.isEmpty {
                let expandedFilter = FileHealthView.expandHomePrefix(trimmedFilter)
                HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
                    FlowLayout(spacing: GargantuaSpacing.space1) {
                        ForEach(clusters) { cluster in
                            FileHealthPathClusterChip(
                                cluster: cluster,
                                suggestion: tabSuggestions[cluster.id],
                                isActive: expandedFilter == FileHealthView.expandHomePrefix(cluster.id),
                                onSelect: { filterText = cluster.id }
                            )
                        }
                    }

                    if onSuggestClusters != nil, activeAIEngineKind == .mlx {
                        suggestButton(for: tab, clusters: clusters, isSuggesting: isSuggesting)
                    }
                }
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(GargantuaColors.surface1)
    }

    @ViewBuilder
    private func suggestButton(
        for tab: FileHealthCategoryTab,
        clusters: [FileHealthPathCluster],
        isSuggesting: Bool
    ) -> some View {
        let attempted = attemptedSuggestionTabIDs.contains(tab.id)
        let suggestionCount = (clusterSuggestions[tab.id] ?? [:]).count
        let returnedNothing = attempted && suggestionCount == 0

        VStack(alignment: .trailing, spacing: 2) {
            Button {
                Task { await runClusterSuggestion(for: tab, clusters: clusters) }
            } label: {
                HStack(spacing: GargantuaSpacing.space1) {
                    if isSuggesting {
                        AccretionDiskView(activityRate: 18, size: 11)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                    }
                    Text(suggestButtonLabel(
                        isSuggesting: isSuggesting,
                        attempted: attempted,
                        hasSuggestions: suggestionCount > 0
                    ))
                    .font(GargantuaFonts.caption)
                }
                .foregroundStyle(isSuggesting ? GargantuaColors.ink3 : GargantuaColors.accent)
                .padding(.horizontal, GargantuaSpacing.space2)
                .padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: GargantuaRadius.small)
                        .stroke(isSuggesting ? GargantuaColors.borderSoft : GargantuaColors.accent.opacity(0.5), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSuggesting)
            .help(suggestButtonHelp(
                attempted: attempted,
                hasSuggestions: suggestionCount > 0
            ))

            if returnedNothing, !isSuggesting {
                Text("AI returned no suggestions — model may not be downloaded.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
    }

    private func suggestButtonLabel(
        isSuggesting: Bool,
        attempted: Bool,
        hasSuggestions: Bool
    ) -> String {
        if isSuggesting { return "Thinking…" }
        if hasSuggestions { return "Re-suggest" }
        if attempted { return "Try again" }
        return "Suggest"
    }

    private func suggestButtonHelp(attempted: Bool, hasSuggestions: Bool) -> String {
        if hasSuggestions {
            return "Ask the local AI engine to re-label these clusters."
        }
        if attempted {
            return "The local AI engine returned no suggestions on the last attempt. The model may not be downloaded — check Settings."
        }
        return "Ask the local AI engine to label these clusters and recommend safety per group."
    }

    @MainActor
    private func runClusterSuggestion(
        for tab: FileHealthCategoryTab,
        clusters: [FileHealthPathCluster]
    ) async {
        guard let onSuggestClusters,
              !suggestingTabIDs.contains(tab.id),
              !clusters.isEmpty
        else { return }

        let samples = FileHealthPathClusterer.samplesByCluster(
            clusters,
            findings: tab.findings
        )
        let summaries = clusters.map { cluster in
            FileHealthClusterSummary(
                id: cluster.id,
                category: tab.label,
                count: cluster.count,
                totalSize: cluster.totalSize,
                samplePaths: samples[cluster.id] ?? []
            )
        }

        suggestingTabIDs.insert(tab.id)
        defer { suggestingTabIDs.remove(tab.id) }

        let suggestions = await onSuggestClusters(summaries)
        let byID = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.clusterID, $0) })
        clusterSuggestions[tab.id] = byID
        attemptedSuggestionTabIDs.insert(tab.id)
    }
}

private struct FileHealthPathClusterChip: View {
    let cluster: FileHealthPathCluster
    let suggestion: FileHealthClusterSuggestion?
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: GargantuaSpacing.space1) {
                if let suggestion {
                    Circle()
                        .fill(suggestion.safety.tintColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }

                Text(cluster.displayLabel)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(isActive ? GargantuaColors.ink : GargantuaColors.ink2)
                    .fixedSize(horizontal: true, vertical: false)

                if let suggestion {
                    Text("·")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink4)
                    Text(suggestion.label)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Text("\(cluster.count)")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink3)
            }
            .padding(.horizontal, GargantuaSpacing.space2)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .fill(isActive ? GargantuaColors.surface3 : GargantuaColors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .stroke(isActive ? GargantuaColors.accent : GargantuaColors.borderSoft, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(accessibilityLabelText)
    }

    private var helpText: String {
        let baseSize = "\(cluster.count) items in \(cluster.id) (\(AlertItem.formatBytes(cluster.totalSize)))"
        if let suggestion, !suggestion.rationale.isEmpty {
            return "\(suggestion.label) — \(suggestion.rationale)\n\(baseSize)"
        }
        return baseSize
    }

    private var accessibilityLabelText: String {
        if let suggestion {
            return "Filter by \(cluster.displayLabel), \(cluster.count) items, "
                + "AI suggests: \(suggestion.label), \(suggestion.safety.rawValue) safety."
        }
        return "Filter by \(cluster.displayLabel), \(cluster.count) items"
    }
}
