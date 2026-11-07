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

    @Test("a key issued for another product's benefit is refused, and its activation slot released")
    func refusesKeyForAnotherBenefit() async throws {
        let endpoints = UncheckedSendableBox<[String]>([])
        let (session, key) = MockURLProtocol.makeSession { request in
            let endpoint = request.url!.lastPathComponent
            endpoints.value.append(endpoint)
            let body: String
            switch endpoint {
            case "activate": body = #"{"id": "act_1", "license_key": {"status": "granted", "benefit_id": "other-benefit"}}"#
            case "validate": body = #"{"status": "granted", "benefit_id": "other-benefit"}"#
            default: body = ""
            }
            let status = endpoint == "deactivate" ? 204 : 200
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
            return (Data(body.utf8), response)
        }
        defer { MockURLProtocol.removeHandler(for: key) }
        let client = PolarLicenseClient(expectedBenefitID: "gargantua-benefit", session: session)

        await #expect(throws: PolarLicenseError.wrongProduct) {
            try await client.activate(key: "k", label: "Mac", meta: [:])
        }
        // Polar allocated the slot before the client saw the benefit, so the
        // refusal has to hand it back.
        #expect(endpoints.value == ["activate", "deactivate"])

        await #expect(throws: PolarLicenseError.wrongProduct) {
            try await client.validate(key: "k", activationId: "act_1")
        }
        #expect(endpoints.value.last == "validate")
    }

    @Test("the pinned benefit, or an omitted benefit_id, activates normally")
    func acceptsPinnedOrOmittedBenefit() async throws {
        let bodies = UncheckedSendableBox<[String]>([
            #"{"id": "act_1", "license_key": {"status": "granted", "benefit_id": "gargantua-benefit"}}"#,
            #"{"id": "act_2", "license_key": {"status": "granted"}}"#,
        ])
        let (session, key) = MockURLProtocol.makeSession { request in
            let body = bodies.value.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (Data(body.utf8), response)
        }
        defer { MockURLProtocol.removeHandler(for: key) }
        let client = PolarLicenseClient(expectedBenefitID: "gargantua-benefit", session: session)

        let pinned = try await client.activate(key: "k", label: "Mac", meta: [:])
        #expect(pinned.benefitID == "gargantua-benefit")
        let omitted = try await client.activate(key: "k", label: "Mac", meta: [:])
        #expect(omitted.benefitID == nil)
    }
}
