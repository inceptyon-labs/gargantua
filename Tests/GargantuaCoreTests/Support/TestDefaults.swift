import Foundation
import os

/// UserDefaults suites for tests. `removePersistentDomain` empties a suite but
/// leaves its plist in ~/Library/Preferences, so suites named per test run piled
/// up by the tens of thousands. Every suite registered here has its domain and
/// plist removed when the test process exits.
enum TestDefaults {
    private static let names = OSAllocatedUnfairLock(initialState: [String]())
    private static let installCleanup: Void = {
        atexit { TestDefaults.removeAll() }
    }()

    /// A fresh, empty suite named `name`, removed at exit.
    static func suite(_ name: String) -> UserDefaults {
        register(name)
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("Could not create UserDefaults suite \(name)")
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Registers a preferences domain written some other way (CFPreferences)
    /// so its plist is removed at exit too.
    static func register(_ name: String) {
        _ = installCleanup
        names.withLock { $0.append(name) }
    }

    private static func removeAll() {
        let preferences = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        for name in names.withLock({ $0 }) {
            UserDefaults.standard.removePersistentDomain(forName: name)
            CFPreferencesAppSynchronize(name as CFString)
            try? FileManager.default.removeItem(at: preferences.appendingPathComponent("\(name).plist"))
        }
    }
}
