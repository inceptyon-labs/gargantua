import SwiftUI

/// Inline engine picker shown in the File Organizer idle state. Surfaces
/// the choices that are actually configured: the on-device rule-based
/// proposer (always), plus each Anthropic model tier (only when Cloud AI
/// is enabled in Settings AND an API key is on file).
///
/// Selection is two-axis. Picking the rule-based row sets
/// `OrganizerBackendPreference` to `.local`. Picking a cloud tier sets
/// the preference to `.cloud` AND mutates the shared
/// `CloudAIConfiguration.model` so the actual API call routes to the
/// tier the user just picked. The shared model field is also used by
/// the other Cloud AI features — a deliberate v1 simplification (a per-
/// feature override is tracked separately).
struct OrganizerEngineSelector: View {
    @AppStorage(OrganizerBackendPreference.userDefaultsKey)
    var rawBackend = OrganizerBackendPreference.local.rawValue

    @State private var cloudConfig = CloudAIConfiguration()
    @State private var cloudReady = false

    let configStore: CloudAIConfigurationStore
    let keyStore: any CloudAPIKeyStore

    init(
        configStore: CloudAIConfigurationStore = CloudAIConfigurationStore(),
        keyStore: any CloudAPIKeyStore = KeychainCloudAPIKeyStore()
    ) {
        self.configStore = configStore
        self.keyStore = keyStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Text("USE ENGINE")
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink4)

            engineRow(EngineRow(
                isSelected: currentBackend == .local,
                isEnabled: true,
                icon: "cpu",
                title: "On-device rules",
                detail: "Default · Filename heuristics, never leaves your Mac",
                tap: selectLocal
            ))

            ForEach(Self.cloudModels) { model in
                engineRow(EngineRow(
                    isSelected: isCloudSelected(model),
                    isEnabled: cloudReady,
                    icon: "cloud.fill",
                    title: "Cloud · \(model.displayName ?? model.id)",
                    detail: cloudDetail(for: model),
                    tap: { selectCloud(model: model) }
                ))
            }

            if !cloudReady {
                cloudNotReadyHint
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .task { refresh() }
    }

    // MARK: - Selection state

    private var currentBackend: OrganizerBackendPreference {
        OrganizerBackendPreference(rawValue: rawBackend) ?? .local
    }

    private func isCloudSelected(_ model: AnthropicModel) -> Bool {
        currentBackend == .cloud && cloudConfig.model == model.id
    }

    private func selectLocal() {
        rawBackend = OrganizerBackendPreference.local.rawValue
    }

    private func selectCloud(model: AnthropicModel) {
        guard cloudReady else { return }
        rawBackend = OrganizerBackendPreference.cloud.rawValue
        if cloudConfig.model != model.id {
            cloudConfig.model = model.id
            configStore.save(cloudConfig)
        }
    }

    private func refresh() {
        cloudConfig = configStore.load()
        let hasKey = (try? keyStore.hasKey()) ?? false
        cloudReady = cloudConfig.isEnabled && hasKey
    }

    // MARK: - Catalog

    /// Baked-in Anthropic tiers. The full live catalog is reachable via
    /// `AnthropicModelCatalog().loadModels(...)` but for the inline
    /// picker we stick to the three signature tiers (Opus / Sonnet /
    /// Haiku) — anything fancier belongs in the Cloud AI section of
    /// Settings.
    private static let cloudModels: [AnthropicModel] = AnthropicModelCatalog.bakedInModels

    private func cloudDetail(for model: AnthropicModel) -> String {
        switch true {
        case model.id.contains("opus"):
            return "Best groupings · Most expensive"
        case model.id.contains("sonnet"):
            return "Recommended balance"
        case model.id.contains("haiku"):
            return "Fastest · Cheapest cloud option"
        default:
            return ""
        }
    }

    // MARK: - Row

    private struct EngineRow {
        let isSelected: Bool
        let isEnabled: Bool
        let icon: String
        let title: String
        let detail: String
        let tap: () -> Void
    }

    @ViewBuilder
    private func engineRow(_ row: EngineRow) -> some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: row.isSelected ? "circle.inset.filled" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(row.isSelected ? GargantuaColors.accent : GargantuaColors.ink4)

            Image(systemName: row.icon)
                .font(.system(size: 13))
                .foregroundStyle(row.isSelected ? GargantuaColors.accent : GargantuaColors.ink3)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(row.isEnabled ? GargantuaColors.ink : GargantuaColors.ink4)
                Text(row.detail)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
            Spacer()
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(row.isSelected ? GargantuaColors.accent.opacity(0.10) : GargantuaColors.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(
                    row.isSelected ? GargantuaColors.accent : GargantuaColors.borderSoft,
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        .opacity(row.isEnabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture { if row.isEnabled { row.tap() } }
    }

    private var cloudNotReadyHint: some View {
        HStack(spacing: GargantuaSpacing.space1) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(GargantuaColors.ink4)
            Text("Add an Anthropic key in Settings → AI to enable Cloud tiers.")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
        }
        .padding(.top, GargantuaSpacing.space1)
    }
}
