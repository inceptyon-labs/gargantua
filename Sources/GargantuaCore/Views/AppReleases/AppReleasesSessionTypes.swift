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

/// How far an Update All run has got.
public struct AppReleaseBatchProgress: Equatable, Sendable {
    public internal(set) var finished = 0
    public internal(set) var total: Int

    /// The position of the app being updated now.
    public var current: Int { min(finished + 1, total) }

    /// Apps still waiting behind the current one.
    public var waiting: Int { max(total - finished - 1, 0) }
}

/// How a finished Update All run went.
public struct AppReleaseBatchSummary: Equatable, Sendable {
    public internal(set) var updated = 0
    /// Apps left as they were; each row says why.
    public internal(set) var needAttention = 0

    var isEmpty: Bool { updated == 0 && needAttention == 0 }

    var text: String {
        var parts: [String] = []
        if updated > 0 { parts.append("Updated \(updated) app\(updated == 1 ? "" : "s")") }
        if needAttention > 0 { parts.append("\(needAttention) need\(needAttention == 1 ? "s" : "") attention") }
        return parts.joined(separator: " · ")
    }
}

/// An Update All that has to ask first, because some of its apps are open.
struct AppReleaseUpdateAllRequest: Equatable {
    let rows: [AppReleaseRow]
    let openRows: [AppReleaseRow]

    var closedRows: [AppReleaseRow] {
        let open = Set(openRows.map(\.id))
        return rows.filter { !open.contains($0.id) }
    }

    var title: String {
        openRows.count == 1 ? "\(openRows[0].app.name) is open" : "\(openRows.count) apps are open"
    }

    var message: String {
        // Every app is named: agreeing here is consent to quit each one.
        let listed = ListFormatter.localizedString(byJoining: openRows.map(\.app.name))
        return "Updating quits \(listed). Unsaved work in \(openRows.count == 1 ? "it" : "them") may be lost."
    }
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
