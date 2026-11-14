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
}
