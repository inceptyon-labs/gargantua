import SwiftUI

/// Coordinates profile list and editor views, managing state transitions
/// and persistence via PersistenceController.
public struct ProfileContainerView: View {
    let persistence: PersistenceController

    @State private var profiles: [CleanupProfile] = []
    @State private var activeProfileID: String = "developer"
    @State private var editingProfile: CleanupProfile?
    @State private var isCreatingCustom = false

    public init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    public var body: some View {
        Group {
            if let editing = editingProfile {
                ProfileEditorView(
                    profile: editing,
                    onSave: { updated in
                        try? persistence.saveProfile(updated)
                        editingProfile = nil
                        loadProfiles()
                    },
                    onCancel: {
                        if isCreatingCustom {
                            // If cancelling a new custom profile that was never saved, discard it
                            isCreatingCustom = false
                        }
                        editingProfile = nil
                    },
                    onDelete: editing.isCustom ? {
                        try? persistence.deleteProfile(id: editing.id)
                        if activeProfileID == editing.id {
                            activeProfileID = "developer"
                            try? persistence.updateSettings { $0.activeProfileID = "developer" }
                        }
                        editingProfile = nil
                        isCreatingCustom = false
                        loadProfiles()
                    } : nil
                )
            } else {
                ProfileListView(
                    profiles: profiles,
                    activeProfileID: activeProfileID,
                    onSetActive: { id in
                        activeProfileID = id
                        try? persistence.updateSettings { $0.activeProfileID = id }
                    },
                    onEdit: { profile in
                        editingProfile = profile
                    },
                    onCreateCustom: {
                        let id = "custom-\(UUID().uuidString.prefix(8).lowercased())"
                        let custom = CleanupProfile(
                            id: id,
                            name: "Custom Profile",
                            description: "A custom cleanup profile",
                            categories: ["browser_cache", "system_cache", "trash"],
                            isCustom: true
                        )
                        isCreatingCustom = true
                        editingProfile = custom
                    },
                    onDelete: { id in
                        try? persistence.deleteProfile(id: id)
                        if activeProfileID == id {
                            activeProfileID = "developer"
                            try? persistence.updateSettings { $0.activeProfileID = "developer" }
                        }
                        loadProfiles()
                    }
                )
            }
        }
        .onAppear { loadProfiles() }
    }

    private func loadProfiles() {
        profiles = (try? persistence.fetchProfiles()) ?? CleanupProfile.builtIn
        if let settings = try? persistence.fetchSettings() {
            activeProfileID = settings.activeProfileID
        }
    }
}
