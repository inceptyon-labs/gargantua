import SwiftUI

/// Coordinates profile list and editor views, managing state transitions
/// and persistence via PersistenceController.
public struct ProfileContainerView: View {
    let persistence: PersistenceController

    @State private var profiles: [CleanupProfile] = []
    @State private var activeProfileID: String = "developer"
    @State private var editingProfile: CleanupProfile?
    @State private var isCreatingCustom = false
    @State private var persistenceErrorMessage: String?

    public init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    public var body: some View {
        Group {
            if let editing = editingProfile {
                ProfileEditorView(
                    profile: editing,
                    onSave: { updated in
                        saveProfile(updated)
                    },
                    onCancel: {
                        if isCreatingCustom {
                            // If cancelling a new custom profile that was never saved, discard it
                            isCreatingCustom = false
                        }
                        editingProfile = nil
                    },
                    onDelete: editing.isCustom ? {
                        deleteProfile(id: editing.id, closeEditor: true)
                    } : nil
                )
            } else {
                ProfileListView(
                    profiles: profiles,
                    activeProfileID: activeProfileID,
                    onSetActive: { id in
                        setActiveProfile(id)
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
                        deleteProfile(id: id, closeEditor: false)
                    }
                )
            }
        }
        .onAppear { loadProfiles() }
        .alert(
            "Profile Change Failed",
            isPresented: Binding(
                get: { persistenceErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        persistenceErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                persistenceErrorMessage = nil
            }
        } message: {
            Text(persistenceErrorMessage ?? "The profile change could not be saved.")
        }
    }

    private func loadProfiles() {
        do {
            profiles = try persistence.fetchProfiles()
        } catch {
            PersistenceDiagnostics.logFailure("fetchProfiles", error: error)
            profiles = CleanupProfile.builtIn
        }

        do {
            let settings = try persistence.fetchSettings()
            activeProfileID = settings.activeProfileID
        } catch {
            PersistenceDiagnostics.logFailure("fetchSettings", error: error)
        }
    }

    private func saveProfile(_ updated: CleanupProfile) {
        do {
            try persistence.saveProfile(updated)
            editingProfile = nil
            isCreatingCustom = false
            loadProfiles()
        } catch {
            reportPersistenceFailure(
                operation: "saveProfile",
                message: "Gargantua could not save this profile.",
                error: error
            )
        }
    }

    private func deleteProfile(id: String, closeEditor: Bool) {
        do {
            try persistence.deleteProfile(id: id)
            if activeProfileID == id {
                persistActiveProfileFallback()
            }
            if closeEditor {
                editingProfile = nil
                isCreatingCustom = false
            }
            loadProfiles()
        } catch {
            reportPersistenceFailure(
                operation: "deleteProfile",
                message: "Gargantua could not delete this profile.",
                error: error
            )
        }
    }

    private func setActiveProfile(_ id: String) {
        let previousID = activeProfileID
        activeProfileID = id
        do {
            try persistence.updateSettings { $0.activeProfileID = id }
        } catch {
            activeProfileID = previousID
            reportPersistenceFailure(
                operation: "updateSettings activeProfileID",
                message: "Gargantua could not save the active profile change.",
                error: error
            )
        }
    }

    private func persistActiveProfileFallback() {
        activeProfileID = "developer"
        do {
            try persistence.updateSettings { $0.activeProfileID = "developer" }
        } catch {
            reportPersistenceFailure(
                operation: "updateSettings activeProfileID",
                message: "The profile was deleted, but Gargantua could not save the active profile fallback.",
                error: error
            )
        }
    }

    private func reportPersistenceFailure(operation: String, message: String, error: Error) {
        PersistenceDiagnostics.logFailure(operation, error: error)
        persistenceErrorMessage = "\(message) \(error.localizedDescription)"
    }
}
