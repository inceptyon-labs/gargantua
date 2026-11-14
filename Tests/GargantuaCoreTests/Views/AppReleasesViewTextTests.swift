import Foundation
import Testing
@testable import GargantuaCore

@Suite("AppReleasesView text")
struct AppReleasesViewTextTests {
    @Test("a check under a minute old reads as just now")
    func justNow() {
        let now = Date()
        #expect(AppReleasesView.checkedText(lastChecked: now, now: now, capitalized: true) == "Checked just now")
        let recent = AppReleasesView.checkedText(lastChecked: now.addingTimeInterval(-30), now: now, capitalized: false)
        #expect(recent == "checked just now")
        let older = AppReleasesView.checkedText(lastChecked: now.addingTimeInterval(-300), now: now, capitalized: false)
        #expect(!older.contains("just now"))
    }
}
