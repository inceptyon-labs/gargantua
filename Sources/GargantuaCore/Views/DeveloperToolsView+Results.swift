import Foundation
import SwiftUI

extension DeveloperToolsView {
    func resultsView(
        availabilities: [DeveloperToolAvailability],
        previews: [DeveloperTool: PreviewState]
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GargantuaSpacing.space4) {
                ForEach(availabilities.filter(\.isInstalled), id: \.tool) { availability in
                    DeveloperToolPanel(
                        availability: availability,
                        preview: previews[availability.tool] ?? .loading,
                        executingOperationID: session.executingOperationID,
                        executionNotices: session.executionNotices,
                        dockerLifecycleActivity: availability.tool == .docker ? session.dockerLifecycleActivity : nil,
                        onRetry: {
                            Task { await reloadPreview(for: availability.tool) }
                        },
                        onRun: { operation, preview in
                            session.pendingExecution = ExecutionRequest(operation: operation, preview: preview)
                        },
                        onRetryOperation: { operation, preview in
                            session.pendingExecution = ExecutionRequest(operation: operation, preview: preview)
                        },
                        onStartDocker: { startDockerDaemon() },
                        onStopDocker: { stopDockerDaemon() }
                    )
                }

                let missing = availabilities.filter { !$0.isInstalled }
                if !missing.isEmpty {
                    missingRow(missing: missing)
                }
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space4)
        }
    }

    func missingRow(missing: [DeveloperToolAvailability]) -> some View {
        VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            Text("NOT INSTALLED")
                .font(GargantuaFonts.sectionLabel)
                .tracking(0.8)
                .foregroundStyle(GargantuaColors.ink4)
            ForEach(missing, id: \.tool) { item in
                HStack(spacing: GargantuaSpacing.space2) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(GargantuaColors.ink4)
                    Text(item.tool.displayName)
                        .font(GargantuaFonts.label)
                        .foregroundStyle(GargantuaColors.ink3)
                    Text(item.error ?? "not found")
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink4)
                    Spacer()
                }
            }
        }
        .padding(GargantuaSpacing.space3)
        .background(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .fill(GargantuaColors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.medium)
                .stroke(GargantuaColors.borderSoft, lineWidth: 1)
        )
    }
}
