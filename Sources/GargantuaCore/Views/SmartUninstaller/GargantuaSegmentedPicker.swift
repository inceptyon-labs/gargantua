import SwiftUI

/// Segmented-style picker with explicitly-drawn unselected pills.
///
/// The native `.pickerStyle(.segmented)` renders unselected segments with
/// minimal contrast against the Gargantua void-dark theme — users couldn't
/// tell "Size" and "Last used" existed as clickable options at all. This
/// replacement draws a visible track and pill for every option so the set
/// of choices is always discoverable.
public struct GargantuaSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var accessibilityLabel: String?

    public init(
        selection: Binding<Value>,
        options: [(value: Value, label: String)],
        accessibilityLabel: String? = nil
    ) {
        self._selection = selection
        self.options = options
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(GargantuaFonts.caption.weight(.medium))
                        .foregroundStyle(
                            selection == option.value
                                ? Color.white
                                : GargantuaColors.ink2
                        )
                        .padding(.vertical, 4)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                .fill(
                                    selection == option.value
                                        ? GargantuaColors.accent
                                        : GargantuaColors.surface2
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(selection == option.value ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: GargantuaRadius.small + 2)
                .fill(GargantuaColors.surface1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel ?? "")
    }
}
