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

    @Test("just now covers 59 s, not 60 s, and future dates")
    func justNowBoundaries() {
        let now = Date()
        let at59 = AppReleasesView.checkedText(lastChecked: now.addingTimeInterval(-59), now: now, capitalized: false)
        #expect(at59 == "checked just now")
        let at60 = AppReleasesView.checkedText(lastChecked: now.addingTimeInterval(-60), now: now, capitalized: false)
        #expect(!at60.contains("just now"))
        let future = AppReleasesView.checkedText(lastChecked: now.addingTimeInterval(10), now: now, capitalized: false)
        #expect(future == "checked just now")
    }
}
