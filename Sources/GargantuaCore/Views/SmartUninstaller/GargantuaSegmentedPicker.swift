import SwiftUI

/// Segmented-style picker with explicitly-drawn unselected pills.
///
/// The native `.pickerStyle(.segmented)` renders unselected segments with
/// minimal contrast against the Gargantua void-dark theme — users couldn't
/// tell "Size" and "Last used" existed as clickable options at all. This
/// replacement draws a visible track and pill for every option so the set
/// of choices is always discoverable.
///
/// Two flavors:
/// - **Binding flavor** — `init(selection: Binding<Value>, ...)`. Standard
///   pick-one-of-N where re-tapping the active segment is a no-op.
/// - **Callback flavor** — `init(selection: Value, ..., onSelect:)`. Lets
///   the caller fire a callback even when the active segment is re-tapped,
///   and optionally render a trailing glyph on each segment (used by the
///   uninstaller's sort picker to show direction + flip on re-tap).
public struct GargantuaSegmentedPicker<Value: Hashable>: View {
    private let options: [(value: Value, label: String)]
    private let trailingGlyph: ((Value) -> Image?)?
    private let activeTooltip: String?
    private let accessibilityLabel: String?

    private let binding: Binding<Value>?
    private let externalSelection: Value?
    private let onSelect: ((Value) -> Void)?

    public init(
        selection: Binding<Value>,
        options: [(value: Value, label: String)],
        accessibilityLabel: String? = nil
    ) {
        self.options = options
        self.binding = selection
        self.externalSelection = nil
        self.onSelect = nil
        self.trailingGlyph = nil
        self.activeTooltip = nil
        self.accessibilityLabel = accessibilityLabel
    }

    public init(
        selection: Value,
        options: [(value: Value, label: String)],
        trailingGlyph: ((Value) -> Image?)? = nil,
        activeTooltip: String? = nil,
        accessibilityLabel: String? = nil,
        onSelect: @escaping (Value) -> Void
    ) {
        self.options = options
        self.binding = nil
        self.externalSelection = selection
        self.onSelect = onSelect
        self.trailingGlyph = trailingGlyph
        self.activeTooltip = activeTooltip
        self.accessibilityLabel = accessibilityLabel
    }

    private var currentSelection: Value {
        if let binding { return binding.wrappedValue }
        return externalSelection!
    }

    private func select(_ value: Value) {
        if let binding {
            binding.wrappedValue = value
        } else {
            onSelect?(value)
        }
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                segment(for: option)
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

    @ViewBuilder
    private func segment(for option: (value: Value, label: String)) -> some View {
        let isSelected = currentSelection == option.value
        let glyph = trailingGlyph?(option.value)

        Button {
            select(option.value)
        } label: {
            HStack(spacing: 4) {
                Text(option.label)
                    .font(GargantuaFonts.caption.weight(.medium))
                if let glyph {
                    glyph
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundStyle(isSelected ? Color.white : GargantuaColors.ink2)
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .fill(isSelected ? GargantuaColors.accent : GargantuaColors.surface2)
            )
            .contentShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(isSelected ? (activeTooltip ?? "") : "")
    }
}
