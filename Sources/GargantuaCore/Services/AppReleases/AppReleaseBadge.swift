/// Which count the App Updates sidebar badge shows.
public enum AppReleaseBadge {
    /// The in-app count once the session has checked; before that, the count the
    /// background check stored, if background checks are on.
    public static func count(
        sessionHasChecked: Bool,
        sessionCount: Int,
        backgroundCheckEnabled: Bool,
        storedCount: Int
    ) -> Int {
        if sessionHasChecked { return sessionCount }
        return backgroundCheckEnabled ? storedCount : 0
    }
}
