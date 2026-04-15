import SwiftUI

/// Editor for a cleanup profile — toggle categories on/off, rename custom profiles.
///
/// Built-in profiles allow category toggling only.
/// Custom profiles also allow renaming and deletion.
public struct ProfileEditorView: View {
    let profile: CleanupProfile
    let onSave: (CleanupProfile) -> Void
    let onCancel: () -> Void
    let onDelete: (() -> Void)?

    @State private var name: String
    @State private var description: String
    @State private var enabledCategories: Set<String>

    public init(
        profile: CleanupProfile,
        onSave: @escaping (CleanupProfile) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.profile = profile
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        self._name = State(initialValue: profile.name)
        self._description = State(initialValue: profile.description)
        self._enabledCategories = State(initialValue: Set(profile.categories))
    }

    private var hasChanges: Bool {
        name != profile.name
            || description != profile.description
            || enabledCategories != Set(profile.categories)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !enabledCategories.isEmpty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Button(action: onCancel) {
                    HStack(spacing: GargantuaSpacing.space1) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                        Text("Back")
                            .font(GargantuaFonts.label)
                    }
                    .foregroundStyle(GargantuaColors.ink2)
                }
                .buttonStyle(.plain)

                Spacer()

                if hasChanges && isValid {
                    Button(action: saveProfile) {
                        Text("Save")
                            .font(GargantuaFonts.label)
                            .foregroundStyle(.white)
                            .padding(.horizontal, GargantuaSpacing.space4)
                            .padding(.vertical, GargantuaSpacing.space1)
                            .background(GargantuaColors.accent)
                            .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, GargantuaSpacing.space6)
            .padding(.top, GargantuaSpacing.space6)
            .padding(.bottom, GargantuaSpacing.space5)

            ScrollView {
                VStack(alignment: .leading, spacing: GargantuaSpacing.space6) {
                    // Name + description section
                    VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                        Text("PROFILE")
                            .font(GargantuaFonts.sectionLabel)
                            .foregroundStyle(GargantuaColors.ink4)
                            .tracking(0.8)

                        if profile.isCustom {
                            TextField("Profile name", text: $name)
                                .textFieldStyle(.plain)
                                .font(GargantuaFonts.heading)
                                .foregroundStyle(GargantuaColors.ink)
                                .padding(GargantuaSpacing.space3)
                                .background(GargantuaColors.surface3)
                                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))

                            TextField("Description", text: $description)
                                .textFieldStyle(.plain)
                                .font(GargantuaFonts.body)
                                .foregroundStyle(GargantuaColors.ink2)
                                .padding(GargantuaSpacing.space3)
                                .background(GargantuaColors.surface3)
                                .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.small))
                        } else {
                            Text(profile.name)
                                .font(GargantuaFonts.heading)
                                .foregroundStyle(GargantuaColors.ink)

                            Text(profile.description)
                                .font(GargantuaFonts.body)
                                .foregroundStyle(GargantuaColors.ink2)
                        }
                    }

                    // Categories section
                    VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                        HStack {
                            Text("CATEGORIES")
                                .font(GargantuaFonts.sectionLabel)
                                .foregroundStyle(GargantuaColors.ink4)
                                .tracking(0.8)

                            Spacer()

                            Text("\(enabledCategories.count) of \(ScanCategory.allCases.count)")
                                .font(GargantuaFonts.caption)
                                .foregroundStyle(GargantuaColors.ink3)
                        }

                        VStack(spacing: 1) {
                            ForEach(ScanCategory.allCases) { category in
                                CategoryToggleRow(
                                    category: category,
                                    isEnabled: enabledCategories.contains(category.rawValue),
                                    onToggle: { toggleCategory(category) }
                                )
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: GargantuaRadius.medium))
                    }

                    // Delete button for custom profiles
                    if let onDelete {
                        VStack(alignment: .leading, spacing: GargantuaSpacing.space3) {
                            Rectangle()
                                .fill(GargantuaColors.border)
                                .frame(height: 1)

                            Button(action: onDelete) {
                                HStack(spacing: GargantuaSpacing.space2) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 13))
                                    Text("Delete Profile")
                                        .font(GargantuaFonts.label)
                                }
                                .foregroundStyle(GargantuaColors.protected_)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, GargantuaSpacing.space6)
                .padding(.bottom, GargantuaSpacing.space6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GargantuaColors.void_)
    }

    private func toggleCategory(_ category: ScanCategory) {
        if enabledCategories.contains(category.rawValue) {
            enabledCategories.remove(category.rawValue)
        } else {
            enabledCategories.insert(category.rawValue)
        }
    }

    private func saveProfile() {
        let updated = CleanupProfile(
            id: profile.id,
            name: name.trimmingCharacters(in: .whitespaces),
            description: description.trimmingCharacters(in: .whitespaces),
            categories: ScanCategory.allCases
                .filter { enabledCategories.contains($0.rawValue) }
                .map(\.rawValue),
            safetyOverrides: profile.safetyOverrides,
            isCustom: profile.isCustom
        )
        onSave(updated)
    }
}

// MARK: - Category Toggle Row

private struct CategoryToggleRow: View {
    let category: ScanCategory
    let isEnabled: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: GargantuaSpacing.space3) {
                Image(systemName: category.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isEnabled ? GargantuaColors.ink2 : GargantuaColors.ink4)
                    .frame(width: 20, alignment: .center)

                Text(category.displayName)
                    .font(GargantuaFonts.label)
                    .foregroundStyle(isEnabled ? GargantuaColors.ink : GargantuaColors.ink3)

                Spacer()

                Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isEnabled ? GargantuaColors.accent : GargantuaColors.ink4)
            }
            .padding(.horizontal, GargantuaSpacing.space4)
            .padding(.vertical, GargantuaSpacing.space3)
            .background(isHovered ? GargantuaColors.surface3 : GargantuaColors.surface2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
