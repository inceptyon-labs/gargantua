import Foundation

// MARK: - App Name Lookup

/// Tiny lookup for the most common bundle IDs so users see "Google Chrome"
/// rather than "Chrome" or "google.Chrome". Fall through to humanizing the
/// last segment for anything not listed.
let knownAppNames: [String: String] = [
    "com.google.Chrome": "Google Chrome",
    "com.google.Chrome.canary": "Google Chrome Canary",
    "com.apple.Safari": "Safari",
    "com.apple.dt.Xcode": "Xcode",
    "com.apple.iTunes": "iTunes",
    "com.apple.Music": "Music",
    "com.apple.Photos": "Photos",
    "com.apple.mail": "Mail",
    "com.microsoft.VSCode": "VS Code",
    "com.microsoft.teams2": "Microsoft Teams",
    "com.spotify.client": "Spotify",
    "com.tinyspeck.slackmacgap": "Slack",
    "com.hnc.Discord": "Discord",
    "com.figma.Desktop": "Figma",
    "com.adobe.Photoshop": "Adobe Photoshop",
    "com.adobe.PremierePro": "Adobe Premiere Pro",
    "com.adobe.AfterEffects": "Adobe After Effects",
    "com.adobe.LightroomClassicCC7": "Adobe Lightroom Classic",
    "com.docker.docker": "Docker",
    "company.thebrowser.Browser": "Arc",
    "org.mozilla.firefox": "Firefox",
    "com.brave.Browser": "Brave",
    "com.todesktop.230313mzl4w4u92": "Cursor",
]

func knownAppName(forBundleID bundleID: String) -> String? {
    knownAppNames[bundleID]
}
