import SwiftUI

struct DevArtifactCategorySelectionView: View {
    let profile: CleanupProfile
    let detectionState: EcosystemDetectionState
    let selectedBucketIDs: Set<String>
    let detectedEcosystemIDs: Set<String>
    let bucketEstimates: [String: Int64]
    let scanProgress: ScanProgress
    let isScanRequested: Bool
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    let onInvertSelection: () -> Void
    let onToggleBucket: (String) -> Void
    let onStartScan: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeaderView(
                title: "Dev Artifact Purge",
                subtitle: "Find build artifacts the tools forgot. Caches, DerivedData, node_modules — pulled straight off the disk.",
                subtitleStyle: .voice
            )

            ZStack {
                switch detectionState {
                case .pending, .detecting:
                    detectingPlaceholder
                        .transition(.opacity)
                case .complete:
                    VStack(spacing: 0) {
                        bucketToolbar

                        Rectangle()
                            .fill(GargantuaColors.borderSoft)
                            .frame(height: 1)

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                                bucketSection(
                                    title: "ECOSYSTEMS",
                                    buckets: bucketsInTier(.ecosystem)
                                )

                                bucketSection(
                                    title: "CROSS-CUTTING",
                                    buckets: bucketsInTier(.crossCutting)
                                )
                            }
                            .padding(.bottom, GargantuaSpacing.space2)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !profile.safetyOverrides.isEmpty {
                DevArtifactProfileOverrideBanner(profile: profile)
            }

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            scanFooter
        }
    }
}

private extension DevArtifactCategorySelectionView {
    private var detectingPlaceholder: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Spacer()
            AccretionDiskView(activityRate: 12, size: 28, color: GargantuaColors.accretion)
            Text("Detecting ecosystems…")
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bucketToolbar: some View {
        let totalBuckets = DevArtifactBucket.catalog.count
        let selectedCount = selectedBucketIDs.count
        let detectedCount = detectedEcosystemIDs.count

        return HStack(spacing: GargantuaSpacing.space3) {
            toolbarButton("All", action: onSelectAll)
            toolbarDot
            toolbarButton("None", action: onDeselectAll)
            toolbarDot
            toolbarButton("Invert", action: onInvertSelection)

            Spacer()

            HStack(spacing: GargantuaSpacing.space2) {
                Text("\(selectedCount) / \(totalBuckets) selected")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
                    .monospacedDigit()

                toolbarDot

                detectionChip(count: detectedCount)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space2)
    }

    @ViewBuilder
    private func detectionChip(count: Int) -> some View {
        if count > 0 {
            HStack(spacing: GargantuaSpacing.space1) {
                Circle()
                    .fill(GargantuaColors.safe)
                    .frame(width: 5, height: 5)
                Text("\(count) on disk")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .monospacedDigit()
            }
        } else {
            HStack(spacing: GargantuaSpacing.space1) {
                Circle()
                    .fill(GargantuaColors.ink4)
                    .frame(width: 5, height: 5)
                Text("0 on disk: using defaults")
                    .font(GargantuaFonts.caption.italic())
                    .foregroundStyle(GargantuaColors.ink3)
            }
        }
    }

    private func toolbarButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.accent)
        }
        .buttonStyle(.plain)
    }

    private var toolbarDot: some View {
        Text("·")
            .font(GargantuaFonts.caption)
            .foregroundStyle(GargantuaColors.ink4)
    }

    private func bucketsInTier(_ tier: DevArtifactBucket.Tier) -> [DevArtifactBucket] {
        DevArtifactBucket.catalog
            .filter { $0.tier == tier }
            .sorted(by: { $0.priority < $1.priority })
    }

    private func bucketSection(title: String, buckets: [DevArtifactBucket]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink3)
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.top, GargantuaSpacing.space3)
                .padding(.bottom, GargantuaSpacing.space2)

            ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                bucketRow(bucket)

                if index < buckets.count - 1 {
                    Rectangle()
                        .fill(GargantuaColors.borderSoft)
                        .frame(height: 1)
                }
            }
        }
    }

    private func bucketRow(_ bucket: DevArtifactBucket) -> some View {
        let isSelected = selectedBucketIDs.contains(bucket.id)
        let isDetected = bucket.tier == .ecosystem && detectedEcosystemIDs.contains(bucket.id)

        return Button {
            onToggleBucket(bucket.id)
        } label: {
            HStack(spacing: GargantuaSpacing.space3) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? GargantuaColors.accent : GargantuaColors.borderEm)
                    .frame(width: 16, height: 16)

                Image(systemName: bucket.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(bucket.tier == .crossCutting ? GargantuaColors.ink : GargantuaColors.ink2)
                    .frame(width: 20, alignment: .center)

                Text(bucket.label)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(isSelected ? GargantuaColors.ink : GargantuaColors.ink2)

                if isDetected {
                    Circle()
                        .fill(GargantuaColors.safe)
                        .frame(width: 5, height: 5)
                        .help("Detected on disk")
                }

                Spacer()

                if let size = bucketEstimates[bucket.id], size > 0 {
                    Text(AlertItem.formatBytes(size))
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink2)
                }
            }
            .padding(.vertical, GargantuaSpacing.space2)
            .padding(.horizontal, GargantuaSpacing.space4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(bucket.label)
        .accessibilityValue(isSelected ? "selected, on disk" : (isDetected ? "not selected, on disk" : "not selected"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var scanFooter: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            if scanProgress.isScanning || isScanRequested {
                AccretionDiskView(activityRate: 18, size: 14, color: GargantuaColors.accretion)

                Text(scanProgress.currentCategory ?? "Scanning…")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)

                Spacer()
            } else {
                if let firstError = scanProgress.errors.first {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(GargantuaColors.review)

                    Text(firstError)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.review)
                        .lineLimit(1)
                } else {
                    footerEvidence
                }

                Spacer()

                Button(action: onStartScan) {
                    Text("Scan Selected Buckets")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(.white)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
                .disabled(selectedBucketIDs.isEmpty || detectionState != .complete)
                .opacity(selectedBucketIDs.isEmpty || detectionState != .complete ? 0.5 : 1)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
    }

    @ViewBuilder
    private var footerEvidence: some View {
        if selectedBucketIDs.isEmpty {
            Text("Select at least one bucket to scan.")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
        } else {
            let estimatedTotal = selectedBucketIDs.reduce(into: Int64(0)) { sum, id in
                sum += bucketEstimates[id, default: 0]
            }
            HStack(spacing: GargantuaSpacing.space2) {
                Text("\(selectedBucketIDs.count) selected")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
                    .monospacedDigit()

                Text("·")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink4)

                if estimatedTotal > 0 {
                    Text("\(AlertItem.formatBytes(estimatedTotal)) estimated")
                        .font(GargantuaFonts.monoData)
                        .foregroundStyle(GargantuaColors.ink2)
                } else {
                    Text("first scan: sizes appear after")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }
            }
        }
    }
}
