import Foundation

/// Where the App Updates page is: nothing checked yet, a check running, a
/// list on screen, or a check that produced nothing.
public enum AppReleasesPhase: Equatable, Sendable {
    case idle
    case checking
    case ready
    case failed(String)
}

/// Which rows the list shows.
public enum AppReleasesFilter: String, CaseIterable, Sendable {
    case updates
    case all
    case ignored

    var label: String {
        switch self {
        case .updates: "Updates"
        case .all: "All"
        case .ignored: "Ignored"
        }
    }
}

/// What the last install attempt on a row left behind.
public enum AppReleaseRowMessage: Equatable, Sendable {
    case installed(String)
    /// Installed, but with something the user should look at.
    case installedWithWarning(String)
    case failed(String)
}
