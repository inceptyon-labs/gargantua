import Foundation

/// User-selectable backend for the AI file organizer.
///
/// Cloud routes folder listings through Anthropic via the existing
/// `CloudAIService`; Local uses the on-device rule-based proposer with
/// no network round-trip. Persisted via `UserDefaults` under
/// `userDefaultsKey`. Defaults to `.local` so an unconfigured install
/// still has a working organizer.
public enum OrganizerBackendPreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case local
    case mlx
    case cloud
    case claudeCode

    public static let userDefaultsKey = "organizer.backendPreference"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .local: "On-device rules"
        case .mlx: "On-device · MLX"
        case .cloud: "Cloud AI (Anthropic)"
        case .claudeCode: "Claude Code agent"
        }
    }

    public var settingsDescription: String {
        switch self {
        case .local:
            return "Filename heuristics and date binning. Never leaves your Mac."
        case .mlx:
            return "Local MLX model — real AI, no network. Requires a downloaded model."
        case .cloud:
            return "Smarter groupings via Anthropic. Sends filenames + sizes only — no contents."
        case .claudeCode:
            return "Routes through your claude CLI. Uses whatever model and auth the agent has."
        }
    }

    public var systemImage: String {
        switch self {
        case .local: "cpu"
        case .mlx: "brain"
        case .cloud: "cloud"
        case .claudeCode: "terminal"
        }
    }

    public static func stored(in defaults: UserDefaults = .standard) -> OrganizerBackendPreference {
        guard let raw = defaults.string(forKey: userDefaultsKey),
              let value = OrganizerBackendPreference(rawValue: raw)
        else {
            return .local
        }
        return value
    }

    public func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.userDefaultsKey)
    }
}
