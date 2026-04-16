import SwiftUI

// MARK: - Deep Clean View

/// Full-system cleanup scan view using `MoCleanAdapter`.
///
/// Shows a scan trigger button, progress during scan, and results
/// in the three-bucket `ScanBucketListView` pattern.
public struct DeepCleanView: View {
    private let adapter: MoCleanAdapter

    @State private var scanProgress = ScanProgress()
    @State private var scanResults: [ScanResult]?
    @State private var scanDuration: TimeInterval = 0
    @State private var selectedResultIDs: Set<String> = []
    @State private var isScanning = false

    public init(adapter: MoCleanAdapter) {
        self.adapter = adapter
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let results = scanResults {
                resultsView(results)
            } else {
                startView
            }
        }
        .background(GargantuaColors.void_)
    }

    // MARK: - Start View

    private var startView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Deep Clean")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
                Spacer()
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space4)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            // Description
            Spacer()

            VStack(spacing: GargantuaSpacing.space3) {
                Image(systemName: "bubbles.and.sparkles")
                    .font(.system(size: 36))
                    .foregroundStyle(GargantuaColors.ink3)

                Text("System Cleanup")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Text("Scans for browser caches, system logs, temp files, old installers, and other reclaimable space.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Spacer()

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            // Scan button / progress
            scanFooter
        }
    }

    private var scanFooter: some View {
        HStack {
            if isScanning {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, GargantuaSpacing.space2)

                Text(scanProgress.currentCategory ?? "Scanning...")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)

                Spacer()
            } else {
                if scanProgress.errors.isEmpty == false {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(GargantuaColors.review)

                    Text(scanProgress.errors.first ?? "Scan error")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.review)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: startScan) {
                    Text("Start Deep Clean Scan")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(.white)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
    }

    // MARK: - Results

    private func resultsView(_ results: [ScanResult]) -> some View {
        VStack(spacing: 0) {
            // Back header
            HStack {
                Button {
                    scanResults = nil
                } label: {
                    HStack(spacing: GargantuaSpacing.space1) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Back")
                            .font(GargantuaFonts.label)
                    }
                    .foregroundStyle(GargantuaColors.accent)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Deep Clean")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Spacer()

                // Invisible spacer to balance the back button
                HStack(spacing: GargantuaSpacing.space1) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(GargantuaFonts.label)
                }
                .foregroundStyle(.clear)
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space3)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            // Three-bucket scan results
            ScanBucketListView(
                results: results,
                scanDuration: scanDuration,
                selectedIDs: $selectedResultIDs,
                onClean: { /* TODO: trigger confirmation modal */ },
                onCancel: { scanResults = nil }
            )
        }
    }

    // MARK: - Actions

    private func startScan() {
        isScanning = true
        scanProgress = ScanProgress()
        Task {
            let start = Date()
            do {
                let results = try await adapter.scan(progress: scanProgress)
                scanDuration = Date().timeIntervalSince(start)

                // Pre-select safe items
                selectedResultIDs = Set(
                    results.filter { $0.safety == .safe }.map(\.id)
                )
                scanResults = results
                isScanning = false
            } catch {
                isScanning = false
            }
        }
    }
}
