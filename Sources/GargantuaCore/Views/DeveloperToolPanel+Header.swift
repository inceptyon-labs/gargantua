import Foundation
import SwiftUI

extension DeveloperToolPanel {
    var toolHeader: some View {
        HStack(alignment: .center, spacing: GargantuaSpacing.space2) {
            DeveloperToolLogoBadge(tool: availability.tool, size: 28)

            Text(availability.tool.displayName)
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink)
            if let version = availability.version {
                Text(version)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(1)
            }
            statusChip
            if availability.tool == .docker, case .loaded = preview {
                stopDockerButton
            }
            Spacer()
            headerMetric
        }
        .padding(.horizontal, GargantuaSpacing.space4)
        .padding(.vertical, GargantuaSpacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GargantuaColors.surface3)
    }

    @ViewBuilder
    var headerMetric: some View {
        if case .loaded(let p) = preview, p.hasKnownReclaimableBytes {
            HStack(spacing: GargantuaSpacing.space1) {
                Text(Self.formatBytes(p.reclaimableBytes))
                    .font(GargantuaFonts.monoData)
                    .foregroundStyle(GargantuaColors.ink)
                Text("reclaimable")
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
            }
            .padding(.horizontal, GargantuaSpacing.space2)
            .padding(.vertical, GargantuaSpacing.space1)
            .background(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .fill(GargantuaColors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .stroke(GargantuaColors.borderSoft, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    var statusChip: some View {
        let chip = chipState
        if let chip {
            HStack(spacing: GargantuaSpacing.space1) {
                Circle()
                    .fill(chip.color)
                    .frame(width: 6, height: 6)
                Text(chip.label)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink2)
            }
            .padding(.horizontal, GargantuaSpacing.space2)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(chip.color.opacity(0.15))
            )
        }
    }

    var stopDockerButton: some View {
        Button(action: onStopDocker) {
            HStack(spacing: GargantuaSpacing.space1) {
                if dockerLifecycleActivity == .stopping {
                    AccretionDiskView(activityRate: 12, size: 10, color: GargantuaColors.ink2)
                } else {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(dockerLifecycleActivity == .stopping ? "Stopping…" : "Stop")
                    .font(GargantuaFonts.caption)
            }
            .foregroundStyle(GargantuaColors.ink2)
            .padding(.horizontal, GargantuaSpacing.space2)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(GargantuaColors.surface3)
            )
            .overlay(
                Capsule().stroke(GargantuaColors.borderSoft, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(dockerLifecycleActivity != nil)
        .help("Quit Docker Desktop")
        .accessibilityLabel("Stop Docker daemon")
    }
}
