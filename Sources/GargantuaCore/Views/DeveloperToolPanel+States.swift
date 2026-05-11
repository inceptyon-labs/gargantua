import Foundation
import SwiftUI

extension DeveloperToolPanel {
    func daemonStoppedBody(tool: DeveloperTool) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: "powersleep")
                    .foregroundStyle(GargantuaColors.review)
                Text("\(tool.displayName) is installed but the daemon isn't running.")
                    .font(GargantuaFonts.body)
                    .foregroundStyle(GargantuaColors.ink2)
            }

            dockerStartButton(idleTitle: "Start Docker", busyTitle: "Starting Docker…")
        }
    }

    func failureBody(message: String) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            HStack(spacing: GargantuaSpacing.space2) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(GargantuaColors.review)
                Text("Preview failed")
                    .font(GargantuaFonts.label)
                    .foregroundStyle(GargantuaColors.ink)
            }
            Text(message)
                .font(GargantuaFonts.caption)
                .foregroundStyle(GargantuaColors.ink3)
                .lineLimit(5)
                .multilineTextAlignment(.leading)

            HStack(spacing: GargantuaSpacing.space2) {
                Button {
                    onRetry()
                } label: {
                    Text("Try again")
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink)
                        .padding(.horizontal, GargantuaSpacing.space3)
                        .padding(.vertical, GargantuaSpacing.space1)
                        .background(
                            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                                .fill(GargantuaColors.surface3)
                        )
                }
                .buttonStyle(.plain)

                if availability.tool == .docker {
                    dockerStartButton(idleTitle: "Restart Docker", busyTitle: "Restarting Docker…")
                }
            }
        }
    }

    func dockerStartButton(idleTitle: String, busyTitle: String) -> some View {
        Button(action: onStartDocker) {
            HStack(spacing: GargantuaSpacing.space2) {
                if dockerLifecycleActivity == .starting {
                    AccretionDiskView(activityRate: 18, size: 14, color: .white)
                    Text(busyTitle)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(idleTitle)
                }
            }
            .font(GargantuaFonts.label)
            .foregroundStyle(.white)
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space2)
            .background(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .fill(GargantuaColors.accent)
            )
        }
        .buttonStyle(.plain)
        .disabled(dockerLifecycleActivity != nil)
        .accessibilityLabel("\(idleTitle) daemon")
    }
}
