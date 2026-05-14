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
    case cloud

    public static let userDefaultsKey = "organizer.backendPreference"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .local: "On-device"
        case .cloud: "Cloud AI (Anthropic)"
        }
    }

    public var settingsDescription: String {
        switch self {
        case .local:
            return "Filename heuristics and date binning. Never leaves your Mac."
        case .cloud:
            return "Smarter groupings via Anthropic. Sends filenames + sizes only — no contents."
        }
    }

    public var systemImage: String {
        switch self {
        case .local: "cpu"
        case .cloud: "cloud"
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
