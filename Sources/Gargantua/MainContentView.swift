import GargantuaCore
import SwiftUI

/// Root content view for the Gargantua window.
///
/// Fills the entire window with ``GargantuaColors/void_`` so no system
/// chrome is visible behind the transparent titlebar.
/// Shows the permission request flow on first launch.
struct MainContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            if !hasCompletedOnboarding {
                PermissionRequestFlowView(isComplete: $hasCompletedOnboarding)
            }
        }
    }
}
