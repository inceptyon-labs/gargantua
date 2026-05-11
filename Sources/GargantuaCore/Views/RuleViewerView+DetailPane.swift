import SwiftUI

extension RuleViewerView {
    var detailPane: some View {
        Group {
            if let rule = selectedRule {
                ScrollView {
                    VStack(alignment: .leading, spacing: GargantuaSpacing.space5) {
                        ruleDetailHeader(rule)
                        ruleMetadata(rule)
                        rulePaths(rule)
                        ruleYAML(rule)
                        pathExclusionSection
                    }
                    .padding(GargantuaSpacing.space6)
                }
            } else {
                VStack(spacing: GargantuaSpacing.space3) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(GargantuaColors.ink4)
                    Text("Select a rule to view details")
                        .font(GargantuaFonts.body)
                        .foregroundStyle(GargantuaColors.ink3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(GargantuaColors.void_)
    }

    func ruleDetailHeader(_ rule: ScanRule) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Text(rule.name)
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            Text(rule.explanation)
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
        }
    }

    func ruleMetadata(_ rule: ScanRule) -> some View {
        HStack(spacing: GargantuaSpacing.space4) {
            metadataBadge(
                label: rule.safety.rawValue.uppercased(),
                color: safetyColor(rule.safety)
            )

            metadataItem(label: "Confidence", value: "\(rule.confidence)%")
            metadataItem(label: "Source", value: rule.source.name)
            metadataItem(label: "Category", value: rule.category)

            if rule.regenerates {
                metadataBadge(label: "REGENERATES", color: GargantuaColors.accent)
            }
        }
    }

    func rulePaths(_ rule: ScanRule) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Text("Paths")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink2)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                ForEach(rule.paths, id: \.self) { path in
                    Text(path)
                        .font(GargantuaFonts.monoPath)
                        .foregroundStyle(GargantuaColors.ink)
                        .textSelection(.enabled)
                }

                if !rule.exclude.isEmpty {
                    Text("Excludes")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink4)
                        .padding(.top, GargantuaSpacing.space1)

                    ForEach(rule.exclude, id: \.self) { pattern in
                        Text(pattern)
                            .font(GargantuaFonts.monoPath)
                            .foregroundStyle(GargantuaColors.ink3)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(GargantuaSpacing.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GargantuaColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
    }

    func ruleYAML(_ rule: ScanRule) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Text("YAML Definition")
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink2)

            ScrollView(.horizontal, showsIndicators: false) {
                YAMLHighlightedView(yaml: renderYAML(rule))
                    .padding(GargantuaSpacing.space3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GargantuaColors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
        }
    }

    var pathExclusionSection: some View {
        PathExclusionSettingsSection(
            persistence: persistence,
            title: "Exclusions",
            subtitle: "Excluded paths are left untouched by cleanup scans."
        )
    }

    private func metadataBadge(label: String, color: Color) -> some View {
        Text(label)
            .font(GargantuaFonts.caption)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, GargantuaSpacing.space2)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
    }

    private func metadataItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink4)
            Text(value)
                .font(GargantuaFonts.label)
                .foregroundStyle(GargantuaColors.ink)
        }
    }
}
