import AppKit
import SwiftUI

// Single row in the Background Items review pane.
//
// Mirrors the scan-result row pattern: 3pt safety bar on the leading edge,
// safety-tinted background, leading-aligned label + explanation + path.
// Trailing slot carries vendor + reason chips and the Reveal button. The
// expanded section pulls in the full identity / signature detail; both
// halves share state so SwiftUI keeps the toggle animation smooth.
// swiftlint:disable:next type_body_length
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
    private var supportsActions: Bool {
        switch item.source {
        case .userLaunchAgent, .systemLaunchAgent, .launchDaemon: true
        case .startupItem, .loginItem: false
        }
    }

    /// Treat the row as disabled if either the plist's `Disabled` key is set
    /// or the user just ran disable in this session (runtime state lives in
    /// launchd's disabled DB, not the plist).
    private var isDisabled: Bool {
        item.reasons.contains(.disabledFlag) || isSessionDisabled
    }

    private var canDelete: Bool {
        guard supportsActions, item.plistPath != nil else { return false }
        return item.safety != .protected_ && isDisabled
    }

    private var canDisable: Bool {
        supportsActions && item.safety != .protected_ && !isDisabled
    }

    private var canEnable: Bool {
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
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                        Text("Explain")
                            .font(GargantuaFonts.caption)
                    }
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

    // MARK: - Expanded detail

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Rectangle()
                .fill(GargantuaColors.borderSoft)
                .frame(height: 1)
                .padding(.horizontal, GargantuaSpacing.space3)

            VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                detailRow(label: "Label", value: item.label)
                if let exe = item.executablePath {
                    detailRow(label: "Executable", value: exe, mono: true)
                }
                if let identity = item.identity {
                    if let team = identity.teamIdentifier {
                        detailRow(label: "Team ID", value: team, mono: true)
                    }
                    if let signing = identity.signingIdentity {
                        detailRow(label: "Signed by", value: signing)
                    }
                    if let bundle = identity.bundleIdentifier {
                        detailRow(label: "Bundle ID", value: bundle, mono: true)
                    }
                    if let version = identity.bundleShortVersion {
                        detailRow(label: "Version", value: version)
                    }
                    detailRow(label: "Vendor", value: vendorLabel(identity.vendor))
                    if let valid = identity.signatureValid {
                        detailRow(
                            label: "Signature",
                            value: valid ? "Valid" : "Invalid"
                        )
                    }
                    if let notarized = identity.isNotarized {
                        detailRow(
                            label: "Notarized",
                            value: notarized ? "Yes" : "No"
                        )
                    }
                }
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space2)
            .padding(.leading, GargantuaSpacing.space1)
        }
    }

    private func detailRow(label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space3) {
            Text(label)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .frame(width: 92, alignment: .leading)

            Text(value)
                .font(mono ? GargantuaFonts.monoData : GargantuaFonts.body)
                .foregroundStyle(GargantuaColors.ink)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenu: some View {
        if item.source == .loginItem, let onOpenLoginSettings {
            Button("Open Login Items in System Settings") { onOpenLoginSettings() }
        }
        if item.plistPath != nil {
            Button("Reveal plist in Finder") { onReveal() }
        }
        if let exe = item.executablePath, !exe.isEmpty {
            Button("Reveal executable in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: exe)])
            }
        }
        if let onExplain {
            Button("Explain with AI") { onExplain() }
        }
        if let onAction, supportsActions {
            Divider()
            if canDisable {
                Button("Disable") { onAction(.disable) }
            }
            if canEnable {
                Button("Re-enable") { onAction(.enable) }
            }
            if canDelete {
                Button("Move plist to Trash") { onAction(.delete) }
            }
        }
        Button("Copy label") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.label, forType: .string)
        }
    }

    // MARK: - Tokens

    private var safetyColor: Color {
        switch item.safety {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }

    private var safetyTint: Color {
        switch item.safety {
        case .safe: GargantuaColors.safeDim
        case .review: GargantuaColors.reviewDim
        case .protected_: GargantuaColors.protectedDim
        }
    }

    private var safetySFSymbol: String {
        switch item.safety {
        case .safe: "checkmark.shield.fill"
        case .review: "questionmark.diamond.fill"
        case .protected_: "lock.fill"
        }
    }

    private func chipBackground(for reason: BackgroundItemReason) -> Color {
        switch reason {
        case .sensitiveVendor, .unsigned, .orphaned, .orphanedVendor:
            GargantuaColors.review.opacity(0.18)
        case .system:
            GargantuaColors.protected_.opacity(0.18)
        case .disabledFlag:
            GargantuaColors.ink4.opacity(0.18)
        case .listensForRequests, .persistentlyRunning, .scheduled:
            GargantuaColors.accent.opacity(0.14)
        }
    }

    private func chipForeground(for reason: BackgroundItemReason) -> Color {
        switch reason {
        case .sensitiveVendor, .unsigned, .orphaned, .orphanedVendor:
            GargantuaColors.review
        case .system:
            GargantuaColors.protected_
        case .disabledFlag:
            GargantuaColors.ink2
        case .listensForRequests, .persistentlyRunning, .scheduled:
            GargantuaColors.accent
        }
    }

    private func vendorLabel(_ vendor: VendorClassification) -> String {
        switch vendor {
        case .apple: "Apple"
        case .thirdPartyKnown: "Third-party (known)"
        case .thirdPartyUnknown: "Third-party (unknown)"
        case .unsigned: "Unsigned / unverifiable"
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
