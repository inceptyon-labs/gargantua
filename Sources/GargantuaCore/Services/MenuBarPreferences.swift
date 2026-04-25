import Foundation

/// UserDefaults keys shared by the menu bar scene and Settings.
public enum MenuBarPreferences {
    public static let widgetEnabledKey = "menuBarWidgetEnabled"
    public static let launchAtLoginEnabledKey = "launchAtLoginEnabled"
    public static let alertsSnoozedUntilKey = "menuBarAlertsSnoozedUntil"

    public static let defaultWidgetEnabled = true
    public static let defaultLaunchAtLoginEnabled = false
}
