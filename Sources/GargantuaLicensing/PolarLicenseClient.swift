import Foundation

public struct PolarActivation: Sendable, Equatable {
    public let activationId: String
    public let status: LicenseKeyStatus
    public let email: String?
    public let name: String?
}

public struct PolarValidation: Sendable, Equatable {
    public let status: LicenseKeyStatus
    public let email: String?
    public let name: String?
}

public enum PolarLicenseError: Error, Sendable, Equatable {
    /// HTTP 403 NotPermitted — activation limit reached or activation disabled.
    case activationLimitReached
    /// HTTP 404 — key not found, or a stale activation_id.
    case notFound
    /// Other non-success HTTP status.
    case server(Int, String)
    /// Transport failure (offline, timeout, DNS).
    case network(String)
    /// Response body didn't decode.
    case decoding(String)
    /// Server-side activation succeeded but the receipt couldn't be stored
    /// locally. The activation slot was released, so retrying is safe.
    case receiptSaveFailed(String)
}

public protocol PolarLicenseValidating: Sendable {
    func activate(key: String, label: String, meta: [String: String]) async throws -> PolarActivation
    func validate(key: String, activationId: String?) async throws -> PolarValidation
    func deactivate(key: String, activationId: String) async throws
}

public struct PolarLicenseClient: PolarLicenseValidating {
    private let baseURL: URL
    private let organizationID: String
    private let apiVersion: String
    private let session: URLSession

    public init(
        baseURL: URL = LicensePolarConfig.apiBaseURL,
        organizationID: String = LicensePolarConfig.organizationID,
        apiVersion: String = LicensePolarConfig.apiVersion,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.organizationID = organizationID
        self.apiVersion = apiVersion
        self.session = session
    }

    public func activate(key: String, label: String, meta: [String: String]) async throws -> PolarActivation {
        let body: [String: Any] = [
            "key": key,
            "organization_id": organizationID,
            "label": label,
            "meta": meta,
        ]
        let dto: ActivateDTO = try await post("customer-portal/license-keys/activate", body: body)
        return PolarActivation(
            activationId: dto.id,
            status: dto.licenseKey.status,
            email: dto.licenseKey.customer?.email ?? dto.licenseKey.user?.email,
            name: dto.licenseKey.customer?.name ?? dto.licenseKey.user?.publicName
        )
    }

    public func validate(key: String, activationId: String?) async throws -> PolarValidation {
        var body: [String: Any] = [
            "key": key,
            "organization_id": organizationID,
        ]
        if let activationId {
            body["activation_id"] = activationId
        }
        let dto: ValidateDTO = try await post("customer-portal/license-keys/validate", body: body)
        return PolarValidation(
            status: dto.status,
            email: dto.customer?.email ?? dto.user?.email,
            name: dto.customer?.name ?? dto.user?.publicName
        )
    }

    public func deactivate(key: String, activationId: String) async throws {
        let body: [String: Any] = [
            "key": key,
            "organization_id": organizationID,
            "activation_id": activationId,
        ]
        try await postNoContent("customer-portal/license-keys/deactivate", body: body)
    }

    // MARK: - Transport

    private func makeRequest(_ path: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiVersion, forHTTPHeaderField: "Polar-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PolarLicenseError.network("Non-HTTP response")
            }
            return (data, http)
        } catch let error as PolarLicenseError {
            throw error
        } catch {
            throw PolarLicenseError.network(error.localizedDescription)
        }
    }

    private func mapFailure(_ status: Int, _ data: Data) -> PolarLicenseError {
        let decoded = try? JSONDecoder().decode(ErrorDTO.self, from: data)
        switch status {
        case 403:
            return .activationLimitReached
        case 404:
            return .notFound
        default:
            return .server(status, decoded?.detail ?? "Unexpected error")
        }
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let (data, http) = try await send(try makeRequest(path, body: body))
        guard (200 ... 299).contains(http.statusCode) else {
            throw mapFailure(http.statusCode, data)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PolarLicenseError.decoding(error.localizedDescription)
        }
    }

    private func postNoContent(_ path: String, body: [String: Any]) async throws {
        let (data, http) = try await send(try makeRequest(path, body: body))
        guard (200 ... 299).contains(http.statusCode) else {
            throw mapFailure(http.statusCode, data)
        }
    }
}

// MARK: - Wire DTOs (decode only the fields we use)

private struct CustomerDTO: Decodable {
    let email: String?
    let name: String?
}

private struct UserDTO: Decodable {
    let email: String?
    let publicName: String?

    enum CodingKeys: String, CodingKey {
        case email
        case publicName = "public_name"
    }
}

private struct KeyInfoDTO: Decodable {
    let status: LicenseKeyStatus
    let customer: CustomerDTO?
    let user: UserDTO?
}

private struct ActivateDTO: Decodable {
    let id: String
    let licenseKey: KeyInfoDTO

    enum CodingKeys: String, CodingKey {
        case id
        case licenseKey = "license_key"
    }
}

private struct ValidateDTO: Decodable {
    let status: LicenseKeyStatus
    let customer: CustomerDTO?
    let user: UserDTO?
}

private struct ErrorDTO: Decodable {
    let error: String
    let detail: String
}
