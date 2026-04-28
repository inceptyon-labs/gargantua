import Foundation
import SwiftUI

extension DeveloperToolPanel {
    func operationList(
        _ operations: [DeveloperToolCleanupOperation],
        preview: DeveloperToolPreview
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(operations) { operation in
                operationRow(operation, preview: preview)
                if operation.id != operations.last?.id {
                    Rectangle()
                        .fill(GargantuaColors.borderSoft)
                        .frame(height: 1)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .fill(GargantuaColors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .stroke(GargantuaColors.borderSoft, lineWidth: 1)
        )
    }

    func operationRow(
        _ operation: DeveloperToolCleanupOperation,
        preview: DeveloperToolPreview
    ) -> some View {
        let isExecuting = executingOperationID == operation.id
        return VStack(alignment: .leading, spacing: GargantuaSpacing.space2) {
            HStack(alignment: .center, spacing: GargantuaSpacing.space3) {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space1) {
                    HStack(spacing: GargantuaSpacing.space2) {
                        Text(operation.label)
                            .font(GargantuaFonts.label)
                            .foregroundStyle(GargantuaColors.ink)
                        Text(operation.safety.rawValue.capitalized)
                            .font(GargantuaFonts.caption)
                            .foregroundStyle(operation.safety.tintColor)
                    }
                    Text(operation.detail)
                        .font(GargantuaFonts.caption)
                        .foregroundStyle(GargantuaColors.ink3)
                        .lineLimit(2)
                    if let bytes = operation.estimatedReclaimableBytes(in: preview) {
                        Text(Self.formatBytes(bytes) + " previewed")
                            .font(GargantuaFonts.monoData)
                            .foregroundStyle(GargantuaColors.ink2)
                    }
                }
                Spacer(minLength: GargantuaSpacing.space3)
                runButton(operation, preview: preview, isExecuting: isExecuting)
            }

            if let notice = executionNotices[operation.id] {
                executionNotice(notice, operation: operation, preview: preview)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space3)
        .padding(.vertical, GargantuaSpacing.space2)
    }

    func runButton(
        _ operation: DeveloperToolCleanupOperation,
        preview: DeveloperToolPreview,
        isExecuting: Bool
    ) -> some View {
        let isAnyOperationExecuting = executingOperationID != nil
        return Button {
            onRun(operation, preview)
        } label: {
            HStack(spacing: GargantuaSpacing.space1) {
                if isExecuting {
                    AccretionDiskView(activityRate: 18, size: 12, color: .white)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(isExecuting ? "Running" : "Run")
            }
            .font(GargantuaFonts.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, GargantuaSpacing.space3)
            .padding(.vertical, GargantuaSpacing.space1)
            .background(
                RoundedRectangle(cornerRadius: GargantuaRadius.small)
                    .fill(operation.safety == .protected_ ? GargantuaColors.protected_ : GargantuaColors.accent)
            )
        }
        .buttonStyle(.plain)
        .disabled(isAnyOperationExecuting)
        .accessibilityLabel("Run \(operation.label)")
    }

    func executionNotice(
        _ notice: DeveloperToolsView.ExecutionNotice,
        operation: DeveloperToolCleanupOperation,
        preview: DeveloperToolPreview
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GargantuaSpacing.space2) {
            switch notice {
            case .success(let message):
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(GargantuaColors.safe)
                Text(message)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(2)
            case .failure(let message):
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(GargantuaColors.review)
                Text(message)
                    .font(GargantuaFonts.caption)
                    .foregroundStyle(GargantuaColors.ink3)
                    .lineLimit(3)
                Spacer(minLength: GargantuaSpacing.space2)
                Button {
                    onRetryOperation(operation, preview)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(GargantuaFonts.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(GargantuaColors.accent)
            }
        }
        .padding(.horizontal, GargantuaSpacing.space2)
        .padding(.vertical, GargantuaSpacing.space1)
        .background(
            RoundedRectangle(cornerRadius: GargantuaRadius.small)
                .fill(GargantuaColors.surface3)
        )
    }
}
