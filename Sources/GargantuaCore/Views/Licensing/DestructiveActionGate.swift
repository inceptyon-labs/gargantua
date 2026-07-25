import AppKit
import GargantuaLicensing
import SwiftUI

/// Shared sheet wiring for every GUI surface that deletes files — Deep Clean,
/// AI Models, Duplicate Finder, File Health, Dev Artifacts, and the summary
/// "retry failed" path.
///
/// The gate decision itself is made by ``LicenseGate/authorize(_:)``, which
/// mints a ``DestructiveActionAuthorization`` on success or returns the
/// `BlockReason` on failure. A surface stores that reason in its own
/// `blockedReason` state and bails before anything is deleted;
/// ``SwiftUI/View/destructiveActionGate(reason:)`` renders the Unlock sheet
/// from that state.
///
/// Centralizing the sheet here means a new destructive surface reuses the
/// exact same presentation instead of hand-rolling — or forgetting — its own.
public extension View {
    /// Presents the shared Unlock sheet whenever `reason` is non-nil. Attach to
    /// any destructive surface and drive `reason` from the `BlockReason` that
    /// ``LicenseGate/authorize(_:)`` returns on failure.
    func destructiveActionGate(reason: Binding<BlockReason?>) -> some View {
        modifier(DestructiveActionGateSheet(reason: reason))
    }
}

private struct DestructiveActionGateSheet: ViewModifier {
    @Binding var reason: BlockReason?

    func body(content: Content) -> some View {
        content.sheet(item: $reason) { blockReason in
            UnlockGargantuaSheet(
                reason: blockReason,
                onDismiss: { reason = nil },
                onBuy: {
                    NSWorkspace.shared.open(LicensePolarConfig.checkoutURL)
                    reason = nil
                },
                onActivate: { key in
                    switch await LicenseStateModel.shared.activate(key: key) {
                    case .success:
                        return .ok
                    case .failure(let error):
                        return .error(LicenseErrorCopy.message(for: error))
                    }
                }
            )
        }
    }
}
