import SwiftUI

struct DevArtifactResultsView: View {
    let profile: CleanupProfile
    let results: [ScanResult]
    let scanDuration: TimeInterval
    @Binding var selectedResultIDs: Set<String>
    let scanProgress: ScanProgress
    let onExplain: ((ScanResult) -> Void)?
    let onAdvisory: (([ScanResult]) -> Void)?
    let onClean: () -> Void
    let onBack: () -> Void
    let onRescan: () -> Void
    let onResolveFilter: ((String) async -> ScanFilterSet?)?
    let listState: ScanBucketListState

    var body: some View {
        VStack(spacing: 0) {
            ScanResultsHeader(
                title: "Dev Artifact Purge",
                onBack: onBack,
                onRescan: onRescan,
                isBusy: scanProgress.isScanning
            )

            if !profile.safetyOverrides.isEmpty {
                DevArtifactProfileOverrideBanner(profile: profile)

                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)
            }

            if !scanProgress.errors.isEmpty {
                DevArtifactScanWarningsBanner(errors: scanProgress.errors)

                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)
            }

            ScanBucketListView(
                results: results,
                scanDuration: scanDuration,
                selectedIDs: $selectedResultIDs,
                onExplain: onExplain,
                onClean: onClean,
                onRescan: onRescan,
                onAdvisoryForReview: onAdvisory,
                onResolveNaturalLanguageFilter: onResolveFilter,
                listState: listState
            )
        }
    }
}
