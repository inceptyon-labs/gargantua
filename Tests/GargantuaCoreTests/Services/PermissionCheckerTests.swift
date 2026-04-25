import Foundation
import Testing

@testable import GargantuaCore

@Suite("PermissionChecker")
struct PermissionCheckerTests {

    @Test("hasFullDiskAccess returns a Bool without crashing")
    func hasFullDiskAccessReturnsBool() {
        let result: Bool = PermissionChecker.hasFullDiskAccess
        #expect(result == true || result == false)
    }

    @Test("hasFullDiskAccess is consistent across consecutive reads")
    func hasFullDiskAccessIsConsistent() {
        let first = PermissionChecker.hasFullDiskAccess
        let second = PermissionChecker.hasFullDiskAccess
        #expect(first == second)
    }

    @Test("denied readability probe reports Full Disk Access as unavailable")
    func deniedProbeReportsNoFullDiskAccess() {
        let result = PermissionChecker.hasFullDiskAccess(
            probing: "/private/denied/TCC.db",
            isReadable: { path in
                #expect(path == "/private/denied/TCC.db")
                return false
            }
        )

        #expect(result == false)
    }

    @Test("granted readability probe reports Full Disk Access as available")
    func grantedProbeReportsFullDiskAccess() {
        let result = PermissionChecker.hasFullDiskAccess(
            probing: "/private/granted/TCC.db",
            isReadable: { path in
                #expect(path == "/private/granted/TCC.db")
                return true
            }
        )

        #expect(result == true)
    }
}
