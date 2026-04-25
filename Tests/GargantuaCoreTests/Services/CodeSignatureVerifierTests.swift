import Foundation
import Testing

@testable import GargantuaCore

@Suite("CodeSignatureVerifier")
struct CodeSignatureVerifierTests {

    // MARK: - CodeSignatureInfo model

    @Test("`.unknown` sentinel has nil valid and nil teamIdentifier")
    func unknownSentinel() {
        #expect(CodeSignatureInfo.unknown.valid == nil)
        #expect(CodeSignatureInfo.unknown.teamIdentifier == nil)
    }

    @Test("CodeSignatureInfo is Equatable across all field combinations")
    func equatable() {
        let a = CodeSignatureInfo(valid: true, teamIdentifier: "EQHXZ8M8AV")
        let b = CodeSignatureInfo(valid: true, teamIdentifier: "EQHXZ8M8AV")
        let c = CodeSignatureInfo(valid: true, teamIdentifier: "DIFFERENT")
        let d = CodeSignatureInfo(valid: false, teamIdentifier: "EQHXZ8M8AV")
        let e = CodeSignatureInfo(valid: nil, teamIdentifier: nil)

        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
        #expect(a != e)
        #expect(e == .unknown)
    }

    @Test("Invalid signatures are represented distinctly from unknown signatures")
    func invalidSignatureInfoIsDistinctFromUnknown() {
        let invalid = CodeSignatureInfo(valid: false, teamIdentifier: "TEAMID1234")

        #expect(invalid.valid == false)
        #expect(invalid.teamIdentifier == "TEAMID1234")
        #expect(invalid != .unknown)
    }

    // MARK: - DefaultCodeSignatureVerifier

    @Test("Apple-signed system binary verifies as valid")
    func appleSignedSystemBinaryVerifies() {
        // /bin/ls is shipped and signed by Apple on every macOS install.
        let url = URL(fileURLWithPath: "/bin/ls")
        let info = DefaultCodeSignatureVerifier().verify(bundleURL: url)
        #expect(info.valid == true)
    }

    @Test("Nonexistent path produces `.unknown`")
    func nonexistentPathIsUnknown() {
        let url = URL(fileURLWithPath: "/nonexistent/binary-\(UUID().uuidString)")
        let info = DefaultCodeSignatureVerifier().verify(bundleURL: url)
        #expect(info == .unknown)
    }

    @Test("Unsigned plain file (text) does not validate")
    func unsignedPlainFileDoesNotValidate() throws {
        // Create a plain text file in temp dir; SecStaticCode either fails to
        // create or fails to validate it. Either path is "not valid".
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeSignatureVerifierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("plain.txt")
        try Data("not a binary".utf8).write(to: fileURL)

        let info = DefaultCodeSignatureVerifier().verify(bundleURL: fileURL)
        // Expectation: not validly signed. Either valid == false or .unknown.
        #expect(info.valid != true)
    }
}
