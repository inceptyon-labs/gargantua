import SwiftUI

/// Rule Viewer — browse cleanup rules by category with YAML display and whitelist management.
///
/// Three-column layout: category list (browser/developer/system) → rule list → rule detail.
/// Detail pane shows safety level, confidence, explanation, source, and raw YAML.
/// Bottom section manages the path whitelist persisted via SwiftData.
public struct RuleViewerView: View {
    let persistence: PersistenceController

    @State private var categories: [RuleCategory] = []
    @State private var selectedCategory: String?
    @State private var selectedRuleID: String?
    @State private var whitelistEntries: [PersistedWhitelistEntry] = []
    @State private var newWhitelistPattern = ""
    @State private var isLoading = true

    public init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    private var selectedCategoryRules: [ScanRule] {
        categories.first(where: { $0.name == selectedCategory })?.rules ?? []
    }

    private var selectedRule: ScanRule? {
        selectedCategoryRules.first(where: { $0.id == selectedRuleID })
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    categoryAndRuleList
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GargantuaColors.void_)
        .task {
            await loadRules()
            loadWhitelist()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Rules")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space6)
        .padding(.top, GargantuaSpacing.space6)
        .padding(.bottom, GargantuaSpacing.space3)
    }

    // MARK: - Category + Rule List (left panel)

    private var categoryAndRuleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Category selector
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(categories) { cat in
                        CategoryRow(
                            category: cat,
                            isSelected: selectedCategory == cat.name,
                            onSelect: {
                                selectedCategory = cat.name
                                selectedRuleID = nil
                            }
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
                .padding(.horizontal, GargantuaSpacing.space4)
                .padding(.bottom, GargantuaSpacing.space4)

                // Rule list for selected category
                if !selectedCategoryRules.isEmpty {
                    Rectangle()
                        .fill(GargantuaColors.border)
                        .frame(height: 1)
                        .padding(.horizontal, GargantuaSpacing.space4)
                        .padding(.bottom, GargantuaSpacing.space3)

                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(selectedCategoryRules, id: \.id) { rule in
                            RuleRow(
                                rule: rule,
                                isSelected: selectedRuleID == rule.id,
                                onSelect: { selectedRuleID = rule.id }
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
                    .padding(.horizontal, GargantuaSpacing.space4)
                    .padding(.bottom, GargantuaSpacing.space4)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(GargantuaColors.surface1)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(GargantuaColors.border)
                .frame(width: 1)
        }
    }

    // MARK: - Detail Pane (right panel)

    private var detailPane: some View {
        Group {
            if let rule = selectedRule {
                ScrollView {
                    VStack(alignment: .leading, spacing: GargantuaSpacing.space5) {
                        ruleDetailHeader(rule)
                        ruleMetadata(rule)
                        rulePaths(rule)
                        ruleYAML(rule)
                        whitelistSection
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

    // MARK: - Rule Detail Sections

    private func ruleDetailHeader(_ rule: ScanRule) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Text(rule.name)
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            Text(rule.explanation)
                .font(GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink2)
        }
    }

    private func ruleMetadata(_ rule: ScanRule) -> some View {
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

    private func rulePaths(_ rule: ScanRule) -> some View {
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

    private func ruleYAML(_ rule: ScanRule) -> some View {
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

    // MARK: - Whitelist Section

    private var whitelistSection: some View {
        WhitelistManagementView(
            whitelistEntries: whitelistEntries,
            newWhitelistPattern: $newWhitelistPattern,
            onAddEntry: addWhitelistEntry,
            onRemoveEntry: removeWhitelistEntry
        )
    }

    // MARK: - Data Loading

    private func loadRules() async {
        isLoading = true
        let loader = RuleLoader()
        guard let rulesURL = RuleDirectoryResolver.resolve() else {
            isLoading = false
            return
        }

        do {
            let result = try loader.loadRules(from: rulesURL)
            let grouped = Dictionary(grouping: result.rules) { rule -> String in
                // Derive category folder from the rule's category field
                if rule.category.hasPrefix("browser") { return "browser" }
                if rule.category.hasPrefix("app") || rule.tags.contains("app") {
                    return "apps"
                }
                if rule.tags.contains("developer") || rule.category.hasPrefix("dev")
                    || rule.category.hasPrefix("build") || rule.category.hasPrefix("package") {
                    return "developer"
                }
                return "system"
            }

            categories = ["browser", "apps", "developer", "system"].compactMap { name in
                guard let rules = grouped[name], !rules.isEmpty else { return nil }
                return RuleCategory(name: name, rules: rules.sorted { $0.name < $1.name })
            }

            if selectedCategory == nil {
                selectedCategory = categories.first?.name
            }
        } catch {
            categories = []
        }
        isLoading = false
    }

    private func loadWhitelist() {
        whitelistEntries = (try? persistence.fetchWhitelistEntries()) ?? []
    }

    private func addWhitelistEntry() {
        let pattern = newWhitelistPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        _ = try? persistence.addWhitelistEntry(pattern: pattern)
        newWhitelistPattern = ""
        loadWhitelist()
    }

    private func removeWhitelistEntry(_ pattern: String) {
        try? persistence.removeWhitelistEntry(pattern: pattern)
        loadWhitelist()
    }

    // MARK: - YAML Rendering

    private func renderYAML(_ rule: ScanRule) -> String {
        var lines: [String] = []
        lines.append("- id: \(rule.id)")
        lines.append("  name: \(rule.name)")
        lines.append("  paths:")
        for path in rule.paths {
            lines.append("    - \"\(path)\"")
        }
        if let pattern = rule.pattern {
            lines.append("  pattern: \"\(pattern)\"")
        }
        if !rule.exclude.isEmpty {
            lines.append("  exclude:")
            for ex in rule.exclude {
                lines.append("    - \"\(ex)\"")
            }
        }
        lines.append("  safety: \(rule.safety.rawValue)")
        lines.append("  confidence: \(rule.confidence)")
        lines.append("  explanation: \"\(rule.explanation)\"")
        lines.append("  source:")
        lines.append("    name: \(rule.source.name)")
        if let bundleID = rule.source.bundleID {
            lines.append("    bundle_id: \(bundleID)")
        }
        lines.append("    verify_signature: \(rule.source.verifySignature)")
        lines.append("  regenerates: \(rule.regenerates)")
        if let cmd = rule.regenerateCommand {
            lines.append("  regenerateCommand: \"\(cmd)\"")
        }
        lines.append("  category: \(rule.category)")
        if !rule.tags.isEmpty {
            lines.append("  tags:")
            for tag in rule.tags {
                lines.append("    - \(tag)")
            }
        }
        if !rule.safetyOverrides.isEmpty {
            lines.append("  safety_overrides:")
            for override_ in rule.safetyOverrides {
                lines.append("    - condition: \"\(override_.condition)\"")
                lines.append("      safety: \(override_.safety.rawValue)")
                if let confidence = override_.confidence {
                    lines.append("      confidence: \(confidence)")
                }
                if let suffix = override_.explanationSuffix {
                    lines.append("      explanation_suffix: \"\(suffix)\"")
                }
                if !override_.profiles.isEmpty {
                    lines.append("      profiles:")
                    for profile in override_.profiles {
                        lines.append("        - \(profile)")
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func safetyColor(_ level: SafetyLevel) -> Color {
        switch level {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }
}

// MARK: - Whitelist Management

private struct WhitelistManagementView: View {
    let whitelistEntries: [PersistedWhitelistEntry]
    @Binding var newWhitelistPattern: String
    let onAddEntry: () -> Void
    let onRemoveEntry: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            Rectangle()
                .fill(GargantuaColors.border)
                .frame(height: 1)

            Text("Whitelist")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)

            Text("Whitelisted paths are excluded from cleanup scans.")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)

            // Add entry
            HStack(spacing: GargantuaSpacing.space2) {
                TextField("Path or pattern (e.g. ~/Library/Caches/MyApp)", text: $newWhitelistPattern)
                    .textFieldStyle(.plain)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(GargantuaColors.ink)
                    .padding(GargantuaSpacing.space2)
                    .background(GargantuaColors.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                    .onSubmit { onAddEntry() }

                Button(action: onAddEntry) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(
                            newWhitelistPattern.trimmingCharacters(in: .whitespaces).isEmpty
                                ? GargantuaColors.ink4
                                : GargantuaColors.accent
                        )
                }
                .buttonStyle(.plain)
                .disabled(newWhitelistPattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Existing entries
            if whitelistEntries.isEmpty {
                Text("No whitelist entries yet.")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink4)
                    .padding(.vertical, GargantuaSpacing.space2)
            } else {
                VStack(spacing: 1) {
                    ForEach(whitelistEntries, id: \.pattern) { entry in
                        WhitelistEntryRow(
                            entry: entry,
                            onRemove: { onRemoveEntry(entry.pattern) }
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
            }
        }
    }
}

// MARK: - Supporting Types

struct RuleCategory: Identifiable {
    let name: String
    let rules: [ScanRule]
    var id: String { name }

    var icon: String {
        switch name {
        case "browser": "globe"
        case "apps": "app.badge"
        case "developer": "hammer"
        case "system": "gearshape.2"
        default: "folder"
        }
    }

    var displayName: String {
        name.prefix(1).uppercased() + name.dropFirst()
    }
}

// MARK: - Category Row

private struct CategoryRow: View {
    let category: RuleCategory
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: GargantuaSpacing.space3) {
                Image(systemName: category.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? GargantuaColors.accent : GargantuaColors.ink2)
                    .frame(width: 18, alignment: .center)

                Text(category.displayName)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(isSelected ? GargantuaColors.ink : GargantuaColors.ink2)

                Spacer()

                Text("\(category.rules.count)")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink4)
            }
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(
                isSelected ? GargantuaColors.surface3 :
                isHovered ? GargantuaColors.surface3 : GargantuaColors.surface2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Rule Row

private struct RuleRow: View {
    let rule: ScanRule
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: GargantuaSpacing.space3) {
                Circle()
                    .fill(safetyColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(isSelected ? GargantuaColors.ink : GargantuaColors.ink2)
                        .lineLimit(1)

                    Text(rule.source.name)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink4)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(rule.confidence)%")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink3)
            }
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(
                isSelected ? GargantuaColors.surface3 :
                isHovered ? GargantuaColors.surface3 : GargantuaColors.surface2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var safetyColor: Color {
        switch rule.safety {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }
}

// MARK: - Whitelist Entry Row

private struct WhitelistEntryRow: View {
    let entry: PersistedWhitelistEntry
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "shield.fill")
                .font(.system(size: 12))
                .foregroundStyle(GargantuaColors.ink3)

            Text(entry.pattern)
                .font(GargantuaFonts.monoPath)
                .foregroundStyle(GargantuaColors.ink)
                .lineLimit(1)
                .textSelection(.enabled)

            Spacer()

            Text(entry.createdAt, style: .date)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink4)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(isHovered ? GargantuaColors.protected_ : GargantuaColors.ink4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
        .background(isHovered ? GargantuaColors.surface3 : GargantuaColors.surface2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - YAML Syntax Highlighting

private struct YAMLHighlightedView: View {
    let yaml: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(yaml.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                highlightedLine(line)
            }
        }
    }

    private func highlightedLine(_ line: String) -> some View {
        let parts = tokenize(line)
        return HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, token in
                Text(token.text)
                    .font(GargantuaFonts.monoPath)
                    .foregroundStyle(token.color)
            }
            Spacer(minLength: 0)
        }
    }

    private func tokenize(_ line: String) -> [YAMLToken] {
        // Comment
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            return [YAMLToken(text: line, color: GargantuaColors.ink4)]
        }

        // List item marker
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") && trimmed.contains(":") && !trimmed.dropFirst(2).hasPrefix("\"") {
            // Key-value in list item like "- id: chrome_cache"
            let indent = String(line.prefix(while: { $0 == " " }))
            let afterDash = String(trimmed.dropFirst(2))
            if let colonIdx = afterDash.firstIndex(of: ":") {
                let key = String(afterDash[afterDash.startIndex..<colonIdx])
                let rest = String(afterDash[afterDash.index(after: colonIdx)...])
                return [
                    YAMLToken(text: indent + "- ", color: GargantuaColors.ink3),
                    YAMLToken(text: key, color: GargantuaColors.accent),
                    YAMLToken(text: ":", color: GargantuaColors.ink3),
                    YAMLToken(text: rest, color: valueColor(rest.trimmingCharacters(in: .whitespaces))),
                ]
            }
        }

        if trimmed.hasPrefix("- ") {
            let indent = String(line.prefix(while: { $0 == " " }))
            let value = String(trimmed.dropFirst(2))
            return [
                YAMLToken(text: indent + "- ", color: GargantuaColors.ink3),
                YAMLToken(text: value, color: valueColor(value)),
            ]
        }

        // Key: value
        if let colonIdx = line.firstIndex(of: ":") {
            let key = String(line[line.startIndex..<colonIdx])
            let rest = String(line[line.index(after: colonIdx)...])
            if rest.isEmpty || rest.trimmingCharacters(in: .whitespaces).isEmpty {
                // Key with no value (block mapping parent)
                return [
                    YAMLToken(text: key, color: GargantuaColors.accent),
                    YAMLToken(text: ":" + rest, color: GargantuaColors.ink3),
                ]
            }
            return [
                YAMLToken(text: key, color: GargantuaColors.accent),
                YAMLToken(text: ":", color: GargantuaColors.ink3),
                YAMLToken(text: rest, color: valueColor(rest.trimmingCharacters(in: .whitespaces))),
            ]
        }

        return [YAMLToken(text: line, color: GargantuaColors.ink)]
    }

    private func valueColor(_ value: String) -> Color {
        // Boolean
        if value == "true" || value == "false" {
            return GargantuaColors.review
        }
        // Number
        if Double(value) != nil {
            return GargantuaColors.review
        }
        // String in quotes
        if value.hasPrefix("\"") {
            return GargantuaColors.safe
        }
        // Safety levels
        if value == "safe" || value == "review" || value == "protected" {
            return safetyValueColor(value)
        }
        return GargantuaColors.ink
    }

    private func safetyValueColor(_ value: String) -> Color {
        switch value {
        case "safe": GargantuaColors.safe
        case "review": GargantuaColors.review
        case "protected": GargantuaColors.protected_
        default: GargantuaColors.ink
        }
    }
}

private struct YAMLToken {
    let text: String
    let color: Color
}
