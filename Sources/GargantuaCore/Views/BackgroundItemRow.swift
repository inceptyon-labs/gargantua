import AppKit
import SwiftUI

// Single row in the Background Items review pane.
//
// Mirrors the scan-result row pattern: 3pt safety bar on the leading edge,
// safety-tinted background, leading-aligned label + explanation + path.
// Trailing slot carries vendor + reason chips and the Reveal button. The
// expanded section pulls in the full identity / signature detail; both
// halves share state so SwiftUI keeps the toggle animation smooth.
public struct BackgroundItemRow: View {
    public let item: BackgroundItem
    public let isExpanded: Bool
    public let isBusy: Bool
    public let isSessionDisabled: Bool
    public let onToggleExpand: () -> Void
    public let onReveal: () -> Void
    public let onExplain: (() -> Void)?
    public let onOpenLoginSettings: (() -> Void)?
    public let onAction: ((BackgroundItemAction) -> Void)?

    @State private var isHovered = false

    public init(
        item: BackgroundItem,
        isExpanded: Bool,
        isBusy: Bool = false,
        isSessionDisabled: Bool = false,
        onToggleExpand: @escaping () -> Void,
        onReveal: @escaping () -> Void,
        onExplain: (() -> Void)? = nil,
        onOpenLoginSettings: (() -> Void)? = nil,
        onAction: ((BackgroundItemAction) -> Void)? = nil
    ) {
        self.item = item
        self.isExpanded = isExpanded
        self.isBusy = isBusy
        self.isSessionDisabled = isSessionDisabled
        self.onToggleExpand = onToggleExpand
        self.onReveal = onReveal
        self.onExplain = onExplain
        self.onOpenLoginSettings = onOpenLoginSettings
        self.onAction = onAction
    }

    /// Whether the user can disable / enable / delete this item. Login items
    /// and startup items are out of scope; protected items are read-only.
    var supportsActions: Bool {
        switch item.source {
        case .userLaunchAgent, .systemLaunchAgent, .launchDaemon: true
        case .startupItem, .loginItem: false
        }
    }

    /// Treat the row as disabled if either the plist's `Disabled` key is set
    /// or the user just ran disable in this session (runtime state lives in
    /// launchd's disabled DB, not the plist).
    var isDisabled: Bool {
        item.reasons.contains(.disabledFlag) || isSessionDisabled
    }

    var canDelete: Bool {
        guard supportsActions, item.plistPath != nil else { return false }
        return item.safety != .protected_ && isDisabled
    }

    var canDisable: Bool {
        supportsActions && item.safety != .protected_ && !isDisabled
    }

    var canEnable: Bool {
        supportsActions && item.safety != .protected_ && isDisabled
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedHeader
            if isExpanded {
                expandedDetail
            }
        }
        .background {
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .fill(safetyTint)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(safetyColor)
                        .frame(width: 3)
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: GargantuaRadius.medium,
                                bottomLeadingRadius: GargantuaRadius.medium,
                                bottomTrailingRadius: 0,
                                topTrailingRadius: 0
                            )
                        )
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.borderSoft, lineWidth: 1)
        }
        .onHover { isHovered = $0 }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Collapsed header

    // The outer container is intentionally a tap-gesture-bearing HStack
    // rather than a Button. Wrapping everything in a SwiftUI Button on macOS
    // absorbs the hit before nested action Buttons (Explain, Reveal, chevron)
    // can register, leaving them unresponsive. The tap gesture drives the
    // expand toggle while the nested Buttons stay independently clickable.
    private var collapsedHeader: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            safetyIcon
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: GargantuaSpacing.space2) {
                    Text(item.displayName)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .lineLimit(1)

                    Text(item.source.displayLabel)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                }

                Text(item.explanation)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
                    .lineLimit(2)

                if let plistPath = item.plistPath {
                    Text(plistPath)
                        .font(GargantuaFonts.monoPath)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if item.source == .loginItem {
                    Text("Manage in System Settings → Login Items")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.accent)
                }

                if !item.reasons.isEmpty {
                    reasonChips
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleExpand)

            trailingControls
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .padding(.leading, GargantuaSpacing.space1) // clear the 3pt safety bar
    }

    private var safetyIcon: some View {
        Image(systemName: safetySFSymbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(safetyColor)
            .frame(width: 16, height: 16, alignment: .center)
    }

    private var trailingControls: some View {
        HStack(spacing: GargantuaSpacing.space2) {
            if isBusy {
                AccretionDiskView(activityRate: 12, size: 14, color: GargantuaColors.accretion)
            }

            if isHovered, let onExplain {
                Button(action: onExplain) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .frame(width: 16, height: 16)
                        .foregroundStyle(GargantuaColors.accent)
                }
                .buttonStyle(.plain)
                .help("Generate an AI explanation")
            }

            if isHovered, let onAction, supportsActions {
                actionButtonGroup(onAction: onAction)
            }

            if item.source == .loginItem, let onOpenLoginSettings {
                Button(action: onOpenLoginSettings) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12))
                        .foregroundStyle(GargantuaColors.ink2)
                }
                .buttonStyle(.plain)
                .help("Open Login Items settings")
            } else if item.plistPath != nil {
                Button(action: onReveal) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(GargantuaColors.ink2)
                }
                .buttonStyle(.plain)
                .help("Reveal plist in Finder")
            }

            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GargantuaColors.ink3)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse details" : "Show details")
        }
        .frame(width: 132, alignment: .trailing)
    }

    private func actionButtonGroup(onAction: @escaping (BackgroundItemAction) -> Void) -> some View {
        HStack(spacing: 4) {
            if canDisable {
                Button {
                    onAction(.disable)
                } label: {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(GargantuaColors.review)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .help("Disable this item")
            }

            if canEnable {
                Button {
                    onAction(.enable)
                } label: {
                    Image(systemName: "play.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(GargantuaColors.safe)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .help("Re-enable this item")
            }

            if canDelete {
                Button {
                    onAction(.delete)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(GargantuaColors.review)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .help("Move plist to Trash")
            }
        }
    }

    // MARK: - Reason chips

    private var reasonChips: some View {
        HStack(spacing: GargantuaSpacing.space1) {
            ForEach(Array(item.reasons).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { reason in
                Text(reason.displayLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(chipForeground(for: reason))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: GargantuaRadius.small)
                            .fill(chipBackground(for: reason))
                    }
            }
        }
    }

    private var accessibilityDescription: String {
        let safetyWord = {
            switch item.safety {
            case .safe: "Safe"
            case .review: "Review"
            case .protected_: "Protected"
            }
        }()
        return "\(item.displayName), \(item.source.displayLabel), \(safetyWord). \(item.explanation)"
    }
}
