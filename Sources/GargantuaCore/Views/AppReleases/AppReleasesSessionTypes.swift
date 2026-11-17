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
    /// The update is fine except that another developer signed it; the user
    /// can approve the change and install.
    case signerChanged(AppReleaseSignerChange)
}

/// A change of signer waiting for the user's answer.
struct AppReleasePendingSigner: Equatable {
    let row: AppReleaseRow
    let change: AppReleaseSignerChange
    /// The app is open, so approving also quits it.
    let needsQuit: Bool

    var title: String { "\(row.app.name) has a new signer" }

    var approveLabel: String { needsQuit ? "Trust, Quit and Update" : "Trust and Update" }

    var message: String {
        var text = "Your copy is signed by \(change.fromLabel). This update is signed by \(change.toLabel). "
            + "Apple issued both certificates and notarized the update, but Gargantua can't tell whether "
            + "the app changed hands. Continue only if you expect this."
        if needsQuit { text += " \(row.app.name) is open and will be quit; unsaved work in it may be lost." }
        return text
    }
}

extension AppReleaseSignerChange {
    /// The row's line while the change waits for approval.
    var rowText: String {
        "This update is signed by \(toLabel); your copy is signed by \(fromLabel). Nothing was changed."
    }
}
