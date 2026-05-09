import SwiftUI

/// Confirmation sheet for a Process Inventory mutation.
///
/// `.stop` is destructive in the kernel sense — once the signal lands, in-flight
/// work is gone — so the user gets one clear summary plus, when the source is a
/// launchd job, an explicit warning that the process will respawn unless the
/// source is removed too. `.removeSource` is a navigation handoff, so the copy
/// reframes it as "open the source for review" rather than "delete now."
public struct ProcessActionConfirmation: View {
    public let item: ProcessItem
    public let action: ProcessAction
    public let onConfirm: () -> Void
    public let onCancel: () -> Void

    public init(
        item: ProcessItem,
        action: ProcessAction,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.item = item
        self.action = action
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
            header

            VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
                Text(item.displayName)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
                Text("PID \(item.pid)")
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink2)
                Text(item.launchSource.displayLabel)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
            .padding(GargantuaSpacing.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                    .fill(GargantuaColors.surface2)
            }

            if let secondary = secondaryCopy {
                Text(secondary)
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
            }

            if respawnWarningApplies {
                respawnWarning
            }

            HStack(spacing: GargantuaSpacing.space2) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionLabel, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .tint(actionTint)
            }
        }
        .padding(GargantuaSpacing.space5)
        .frame(width: 440)
        .background(GargantuaColors.surface1)
    }

    // MARK: - Copy

    private var header: some View {
        HStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: actionSymbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(actionTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(GargantuaFonts.heading)
                    .foregroundStyle(GargantuaColors.ink)
                Text(subtitle)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
            }
            Spacer()
        }
    }

    private var respawnWarning: some View {
        HStack(alignment: .top, spacing: GargantuaSpacing.space2) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GargantuaColors.review)
            Text("launchd will respawn this process unless you also remove its source.")
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink2)
            Spacer()
        }
        .padding(GargantuaSpacing.space2)
        .background {
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .fill(GargantuaColors.review.opacity(0.12))
        }
    }

    private var respawnWarningApplies: Bool {
        guard action == .stop else { return false }
        if case .launchd = item.launchSource { return true }
        return false
    }

    private var title: String {
        switch action {
        case .stop: "Stop this process?"
        case .removeSource: "Open this process's source?"
        }
    }

    private var subtitle: String {
        switch action {
        case .stop: "Recorded to the audit log."
        case .removeSource: "Background Items will open with this source highlighted."
        }
    }

    private var secondaryCopy: String? {
        switch action {
        case .stop:
            "SIGTERM first; SIGKILL after a short grace window if the process is still running."
        case .removeSource:
            "Background Items owns the disable/remove flow — Gargantua will navigate there with this entry pre-selected."
        }
    }

    private var actionLabel: String {
        switch action {
        case .stop: "Stop Process"
        case .removeSource: "Open Source"
        }
    }

    private var actionSymbol: String {
        switch action {
        case .stop: "stop.circle.fill"
        case .removeSource: "arrow.up.right.square.fill"
        }
    }

    private var actionTint: Color {
        switch item.safety {
        case .safe: GargantuaColors.safe
        case .review: GargantuaColors.review
        case .protected_: GargantuaColors.protected_
        }
    }
}
