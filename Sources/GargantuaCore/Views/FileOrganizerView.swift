import SwiftUI

/// Top-level page for the AI File Organizer sidebar entry. Wraps the
/// staged-preview surface in the standard `PageHeaderView` so it sits
/// at peer level with Deep Clean, Smart Uninstaller, Duplicate Finder,
/// and File Health. The session it observes is owned by `MainContentView`
/// so the page survives sidebar navigation.
public struct FileOrganizerView: View {
    @ObservedObject private var session: OrganizerSessionState
    private let mlxAvailabilityProvider: @MainActor () -> Bool

    public init(
        session: OrganizerSessionState,
        mlxAvailabilityProvider: @escaping @MainActor () -> Bool = { false }
    ) {
        self.session = session
        self.mlxAvailabilityProvider = mlxAvailabilityProvider
    }

    public var body: some View {
        ZStack {
            GargantuaColors.void_.ignoresSafeArea()

            VStack(spacing: 0) {
                PageHeaderView(
                    title: "File Organizer",
                    subtitle: "AI proposes groupings. You decide what moves.",
                    subtitleStyle: .voice
                )

                OrganizerStagedPreviewView(
                    session: session,
                    mlxAvailabilityProvider: mlxAvailabilityProvider
                )
            }
        }
    }
}
