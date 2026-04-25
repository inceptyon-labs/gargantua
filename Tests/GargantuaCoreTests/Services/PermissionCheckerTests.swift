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
}
