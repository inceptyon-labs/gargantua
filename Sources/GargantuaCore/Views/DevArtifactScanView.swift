import SwiftUI

// MARK: - Dev Artifact Category

/// A scannable category of developer artifacts.
public struct DevArtifactCategory: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let icon: String // SF Symbol name
    /// Estimated size in bytes from the last scan, if available.
    public var estimatedSize: Int64?

    public init(id: String, label: String, icon: String, estimatedSize: Int64? = nil) {
        self.id = id
        self.label = label
        self.icon = icon
        self.estimatedSize = estimatedSize
    }
}

extension DevArtifactCategory {
    /// The default set of dev artifact categories.
    public static let defaults: [DevArtifactCategory] = [
        DevArtifactCategory(id: "node_modules", label: "node_modules", icon: "shippingbox"),
        DevArtifactCategory(id: "xcode", label: "Xcode Derived Data", icon: "hammer"),
        DevArtifactCategory(id: "docker", label: "Docker", icon: "cube"),
        DevArtifactCategory(id: "homebrew", label: "Homebrew", icon: "mug"),
        DevArtifactCategory(id: "python", label: "Python (.venv)", icon: "chevron.left.forwardslash.chevron.right"),
        DevArtifactCategory(id: "rust", label: "Rust (target/)", icon: "gearshape.2"),
        DevArtifactCategory(id: "go", label: "Go (GOPATH/pkg)", icon: "arrow.triangle.branch"),
    ]
}

// MARK: - Dev Artifact Scan View

/// Category-based view for scanning and cleaning developer artifacts.
///
/// Presents a category list (node_modules, Xcode, Docker, etc.) with toggles
/// and estimated sizes. Triggers `MoPurgeAdapter` for selected categories and
/// displays results using `ScanBucketListView`.
public struct DevArtifactScanView: View {
    private let adapter: MoPurgeAdapter
    private let profile: CleanupProfile

    @State private var categories: [DevArtifactCategory] = DevArtifactCategory.defaults
    @State private var selectedCategoryIDs: Set<String> = Set(DevArtifactCategory.defaults.map(\.id))
    @State private var scanProgress = ScanProgress()
    @State private var scanResults: [ScanResult]?
    @State private var scanDuration: TimeInterval = 0
    @State private var selectedResultIDs: Set<String> = []
    @State private var isScanRequested = false

    public init(adapter: MoPurgeAdapter, profile: CleanupProfile = .developer) {
        self.adapter = adapter
        self.profile = profile
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let results = scanResults {
                resultsView(results)
            } else {
                categorySelectionView
            }
        }
        .background(GargantuaColors.void_)
    }

    // MARK: - Category Selection

    private var categorySelectionView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Dev Artifact Purge")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
                Spacer()
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space4)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            // Category list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(categories) { category in
                        categoryRow(category)

                        Rectangle()
                            .fill(GargantuaColors.borderSoft)
                            .frame(height: 1)
                    }
                }
            }

            // Profile override banner
            if !profile.safetyOverrides.isEmpty {
                profileOverrideBanner
            }

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            // Scan button / progress
            scanFooter
        }
    }

    private func categoryRow(_ category: DevArtifactCategory) -> some View {
        let isSelected = selectedCategoryIDs.contains(category.id)

        return Button {
            toggleCategory(category.id)
        } label: {
            HStack(spacing: GargantuaSpacing.space3) {
                // Checkbox
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(
                            isSelected ? GargantuaColors.accent : GargantuaColors.borderEm,
                            lineWidth: 1.5
                        )
                        .frame(width: 16, height: 16)
                        .background(
                            isSelected ? GargantuaColors.accent : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                // Icon
                Image(systemName: category.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(GargantuaColors.ink2)
                    .frame(width: 20, alignment: .center)

                // Label
                Text(category.label)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(isSelected ? GargantuaColors.ink : GargantuaColors.ink2)

                Spacer()

                // Estimated size from last scan
                if let size = category.estimatedSize {
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
    }

    private var profileOverrideBanner: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
            HStack(spacing: GargantuaSpacing.space1) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(GargantuaColors.accent)

                Text("Profile: \(profile.name)")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
            }

            ForEach(Array(profile.safetyOverrides.enumerated()), id: \.offset) { _, override_ in
                HStack(spacing: GargantuaSpacing.space1) {
                    Circle()
                        .fill(safetyColor(override_.safety))
                        .frame(width: 6, height: 6)

                    Text("Auto-classified as \(override_.safety.displayName): \(override_.explanationSuffix ?? override_.condition)")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink2)
                }
                .padding(.leading, GargantuaSpacing.space4)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .background(GargantuaColors.surface1)
    }

    private var scanFooter: some View {
        HStack {
            if scanProgress.isScanning || isScanRequested {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, GargantuaSpacing.space2)

                Text(scanProgress.currentCategory ?? "Scanning...")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)

                Spacer()
            } else {
                Spacer()

                Button(action: startScan) {
                    Text("Scan Selected Categories")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(.white)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.vertical, GargantuaSpacing.space2)
                        .background(GargantuaColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
                .disabled(selectedCategoryIDs.isEmpty)
                .opacity(selectedCategoryIDs.isEmpty ? 0.5 : 1)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
    }

    // MARK: - Results

    private func resultsView(_ results: [ScanResult]) -> some View {
        VStack(spacing: 0) {
            // Back to categories header
            HStack {
                Button {
                    scanResults = nil
                } label: {
                    HStack(spacing: GargantuaSpacing.space1) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Categories")
                            .font(GargantuaFonts.label)
                    }
                    .foregroundStyle(GargantuaColors.accent)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Dev Artifact Purge")
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)

                Spacer()

                // Invisible spacer to balance the back button
                HStack(spacing: GargantuaSpacing.space1) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Categories")
                        .font(GargantuaFonts.label)
                }
                .foregroundStyle(.clear)
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space3)

            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            // Profile override banner in results view too
            if !profile.safetyOverrides.isEmpty {
                profileOverrideBanner

                Rectangle()
                    .fill(GargantuaColors.border)
                    .frame(height: 1)
            }

            // Three-bucket scan results
            ScanBucketListView(
                results: results,
                scanDuration: scanDuration,
                selectedIDs: $selectedResultIDs
            )
        }
    }

    // MARK: - Actions

    private func toggleCategory(_ id: String) {
        if selectedCategoryIDs.contains(id) {
            selectedCategoryIDs.remove(id)
        } else {
            selectedCategoryIDs.insert(id)
        }
    }

    private func startScan() {
        isScanRequested = true
        Task {
            let start = Date()
            do {
                let results = try await adapter.scan(progress: scanProgress)

                // Filter results to selected categories by matching against
                // category or tag patterns
                let filtered = results.filter { result in
                    selectedCategoryIDs.contains(where: { categoryID in
                        matchesCategory(result: result, categoryID: categoryID)
                    })
                }

                scanDuration = Date().timeIntervalSince(start)

                // Update category estimated sizes from scan results
                updateEstimatedSizes(from: results)

                // Pre-select safe items
                selectedResultIDs = Set(
                    filtered.filter { $0.safety == .safe }.map(\.id)
                )
                scanResults = filtered
                isScanRequested = false
            } catch {
                // Errors are already recorded in ScanProgress by the adapter
                isScanRequested = false
            }
        }
    }

    private func matchesCategory(result: ScanResult, categoryID: String) -> Bool {
        switch categoryID {
        case "node_modules":
            return result.category == "dev_artifacts"
                && result.path.contains("node_modules")
        case "xcode":
            return result.category == "dev_artifacts"
                && (result.path.contains("DerivedData") || result.path.contains("Xcode"))
        case "docker":
            return result.category == "docker"
        case "homebrew":
            return result.category == "homebrew"
        case "python":
            return result.category == "dev_artifacts"
                && (result.path.contains(".venv") || result.path.contains("__pycache__"))
        case "rust":
            return result.category == "dev_artifacts"
                && result.path.contains("/target/")
        case "go":
            return result.category == "dev_artifacts"
                && (result.path.contains("GOPATH") || result.path.contains("/go/pkg"))
        default:
            return false
        }
    }

    private func updateEstimatedSizes(from results: [ScanResult]) {
        for index in categories.indices {
            let categoryID = categories[index].id
            let matching = results.filter { matchesCategory(result: $0, categoryID: categoryID) }
            if !matching.isEmpty {
                categories[index].estimatedSize = matching.reduce(0) { $0 + $1.size }
            }
        }
    }

    private func safetyColor(_ level: SafetyLevel) -> Color {
        switch level {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }
}

// MARK: - SafetyLevel Display Name

extension SafetyLevel {
    var displayName: String {
        switch self {
        case .safe: "safe"
        case .review: "review"
        case .protected_: "protected"
        }
    }
}
