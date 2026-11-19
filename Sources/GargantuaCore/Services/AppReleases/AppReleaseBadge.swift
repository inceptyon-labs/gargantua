/// Which count the App Updates sidebar badge shows.
public enum AppReleaseBadge {
    /// The in-app count while the session holds results (nil otherwise). Without
    /// results, the stored count, which the session keeps current after a check
    /// and the background check writes when it is enabled.
    public static func count(
        sessionCount: Int?,
        sessionHasChecked: Bool,
        backgroundCheckEnabled: Bool,
        storedCount: Int
    ) -> Int {
        if let sessionCount { return sessionCount }
        return sessionHasChecked || backgroundCheckEnabled ? storedCount : 0
    }

    /// The names of the `count` apps, for the dashboard card: the in-app ones
    /// while the session holds results, else the stored ones. Empty when those
    /// aren't the ones counted, as when the count was stored before the names
    /// were or isn't shown.
    public static func appNames(count: Int, sessionNames: [String]?, storedNames: [String]) -> [String] {
        let names = sessionNames ?? storedNames
        return names.count == count ? names : []
    }
}

/// How available app updates are described, in the notification and on the
/// dashboard card.
public enum AppReleaseUpdatesText {
    public static func title(count: Int) -> String {
        count == 1 ? "1 app update available" : "\(count) app updates available"
    }

    /// Up to three names, then how many more.
    public static func appList(_ appNames: [String]) -> String {
        var list = appNames.prefix(3).joined(separator: ", ")
        if appNames.count > 3 { list += " and \(appNames.count - 3) more" }
        return list
    }
}
