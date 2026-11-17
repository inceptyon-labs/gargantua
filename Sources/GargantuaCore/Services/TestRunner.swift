import Foundation
import MachO

/// Whether this process is running the test suite.
enum TestRunner {
    static let isActive = NSClassFromString("XCTestCase") != nil || testBundleIsLoaded

    /// XCTest is not always loaded for a Swift Testing run (it isn't on CI's
    /// toolchain), but the `.xctest` bundle that holds the tests is.
    static let testBundleIsLoaded = (0 ..< _dyld_image_count()).contains { index in
        _dyld_get_image_name(index).map { String(cString: $0).contains(".xctest/") } ?? false
    }
}
