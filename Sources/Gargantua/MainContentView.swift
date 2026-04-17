import GargantuaCore
import SwiftUI

/// Root content view for the Gargantua window.
///
/// Fills the entire window with ``GargantuaColors/void_`` so no system
/// chrome is visible behind the transparent titlebar.
/// Shows the permission request flow on first launch, then sidebar + content.
struct MainContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var sidebarSelection: String? = "dashboard"
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
                    VStack(spacing: 0) {
                        if !PermissionChecker.hasFullDiskAccess {
                            PermissionBannerView.fullDiskAccess
                                .padding(.horizontal, GargantuaSpacing.space4)
                                .padding(.top, GargantuaSpacing.space3)
                        }

                        Group {
                            switch sidebarSelection {
                            case "dashboard":
                                DashboardView(sidebarSelection: $sidebarSelection)
                            case "profiles":
                                if let persistence {
                                    ProfileContainerView(persistence: persistence)
                                } else {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            case "deepClean":
                                DeepCleanView(profile: .deep)
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
                                    profile: .devPurge,
                                    scanRoots: resolvedScanRoots
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

    /// Resolve the scan roots for Dev Purge from persisted settings, falling back
    /// to auto-detected defaults when no override is stored or persistence isn't
    /// ready yet.
    ///
    /// Stored entries are trimmed and tilde-expanded; anything empty, a bare `/`,
    /// or a bare `~` is dropped to prevent accidentally widening scan scope to
    /// the whole filesystem or home directory.
    private var resolvedScanRoots: [URL]? {
        guard let persistence,
              let stored = try? persistence.fetchSettings().scanRoots
        else { return nil }

        let urls = stored.compactMap { raw -> URL? in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != "/", trimmed != "~" else { return nil }
            let expanded = (trimmed as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return urls.isEmpty ? nil : urls
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
