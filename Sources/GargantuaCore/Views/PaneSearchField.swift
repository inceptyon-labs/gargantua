import SwiftUI

/// The search field a list pane puts above its rows (Background Items,
/// Rules), styled like Process Inventory's.
struct PaneSearchField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: GargantuaSpacing.space1) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(GargantuaColors.ink4)

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(GargantuaFonts.body)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }

                TextField("", text: $text)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .focused($isFocused)
                    .accessibilityLabel(placeholder)
                    .onExitCommand { text = "" }
            }
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)

            if !text.isEmpty {
                Button { text = "" } label: {
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
                .fill(isFocused ? GargantuaColors.surface4 : GargantuaColors.surface3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(isFocused ? GargantuaColors.borderFocus : GargantuaColors.borderEm, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }
}

extension BackgroundItem {
    /// Case-insensitive match on the label, plist and executable paths, and
    /// the binary's bundle name, bundle ID and team ID.
    func matches(searchQuery query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let fields = [
            label, plistPath, executablePath,
            identity?.bundleName, identity?.bundleIdentifier, identity?.teamIdentifier,
        ]
        return fields.contains { $0?.localizedCaseInsensitiveContains(needle) == true }
    }
}

extension ScanRule {
    /// Case-insensitive match on the rule's id, name, category and paths.
    func matches(searchQuery query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return ([id, name, category] + paths).contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}
