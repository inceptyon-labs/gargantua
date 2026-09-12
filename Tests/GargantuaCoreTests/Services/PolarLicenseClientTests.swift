import Foundation
import Testing
@testable import GargantuaLicensing

@Suite("PolarLicenseClient")
struct PolarLicenseClientTests {

    private static let activateBody = """
    {"id": "act_1", "license_key": {"status": "granted"}}
    """

    /// Polar's API version rolls over quarterly, and an unpinned request follows
    /// whatever "Current" is at the time — which for a shipped build means a
    /// contract it was never compiled against. Every request must carry the pin.
    @Test("every request pins Polar-Version so shipped builds keep their contract")
    func pinsPolarVersionHeader() async throws {
        let captured = UncheckedSendableBox<[URLRequest]>([])
        let (session, key) = MockURLProtocol.makeSession { request in
            captured.value.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (Data(Self.activateBody.utf8), response)
        }
        defer { MockURLProtocol.removeHandler(for: key) }
        let client = PolarLicenseClient(session: session)

        _ = try await client.activate(key: "k", label: "Mac", meta: [:])
        _ = try? await client.validate(key: "k", activationId: "act_1")
        try? await client.deactivate(key: "k", activationId: "act_1")

        #expect(captured.value.count == 3)
        for request in captured.value {
            #expect(request.value(forHTTPHeaderField: "Polar-Version") == LicensePolarConfig.apiVersion)
        }
        #expect(LicensePolarConfig.apiVersion == "2026-04")
    }
}
