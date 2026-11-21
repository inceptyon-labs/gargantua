import Foundation
import os

/// Preferences domains for tests, kept out of ~/Library/Preferences.
///
/// `removePersistentDomain` empties a domain, but cfprefsd writes the emptied
/// domain back to disk a moment later, after any cleanup a short test run can
/// do, so suites named per run piled up there by the tens of thousands. Both
/// UserDefaults and CFPreferences take an absolute path as a domain and store
/// it at that path, so every domain here lives in one temporary folder, removed
/// when the test process exits.
enum TestDefaults {
    private static let names = OSAllocatedUnfairLock(initialState: [String]())
    private static let installCleanup: Void = {
        atexit { TestDefaults.removeAll() }
    }()

    /// Holds every test domain's plist.
    static let folder: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GargantuaTestDefaults-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The domain for `name`, an absolute path in `folder`. Pass it wherever a
    /// suite name or CFPreferences domain is expected.
    static func domain(_ name: String) -> String {
        _ = installCleanup
        let path = folder.appendingPathComponent(name).path
        names.withLock { $0.append(path) }
        return path
    }

    /// A fresh, empty suite for `name`, removed at exit.
    static func suite(_ name: String) -> UserDefaults {
        let domain = domain(name)
        guard let defaults = UserDefaults(suiteName: domain) else {
            preconditionFailure("Could not create UserDefaults suite \(domain)")
        }
        defaults.removePersistentDomain(forName: domain)
        return defaults
    }

    private static func removeAll() {
        for name in names.withLock({ $0 }) {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        try? FileManager.default.removeItem(at: folder)
    }
}
