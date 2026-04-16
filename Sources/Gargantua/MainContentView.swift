import GargantuaCore
import SwiftUI

/// Root content view for the Gargantua window.
///
/// Fills the entire window with ``GargantuaColors/void_`` so no system
/// chrome is visible behind the transparent titlebar.
/// Shows the permission request flow on first launch, then sidebar + content.
struct MainContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var sidebarSelection: String? = "profiles"
    @State private var persistence: PersistenceController?

    var body: some View {
        ZStack {
            GargantuaColors.void_
                .ignoresSafeArea()

            if !hasCompletedOnboarding {
                PermissionRequestFlowView(isComplete: $hasCompletedOnboarding)
            } else {
                HStack(spacing: 0) {
                    SidebarView(selection: $sidebarSelection)

                    // Content area
                    Group {
                        switch sidebarSelection {
                        case "profiles":
                            if let persistence {
                                ProfileContainerView(persistence: persistence)
                            } else {
                                ProgressView()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        case "diskExplorer":
                            DiskExplorerView()
                        case "rules":
                            if let persistence {
                                RuleViewerView(persistence: persistence)
                            } else {
                                ProgressView()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        case "devPurge":
                            DevArtifactScanView(
                                adapter: MoPurgeAdapter(runner: MoleRunner())
                            )
                        case "settings":
                            if let persistence {
                                SettingsView(persistence: persistence)
                            } else {
                                ProgressView()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        default:
                            placeholderView
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onAppear {
                    if persistence == nil {
                        persistence = try? PersistenceController()
                        try? persistence?.bootstrap()
                    }
                }
            }
        }
    }

    private var placeholderView: some View {
        VStack(spacing: GargantuaSpacing.space3) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 32))
                .foregroundStyle(GargantuaColors.ink4)
            Text("Coming Soon")
                .font(GargantuaFonts.heading)
                .foregroundStyle(GargantuaColors.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
