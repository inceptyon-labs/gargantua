import Foundation

public protocol CloudAITransport: Sendable {
    func complete(_ request: CloudAIRequest, apiKey: String) async throws -> CloudAIResponse
    func stream(_ request: CloudAIRequest, apiKey: String) -> AsyncThrowingStream<String, Error>
}

public struct AnthropicMessagesTransport: CloudAITransport {
    public let endpoint: URL
    public let anthropicVersion: String
    public let maxRetries: Int
    private let session: URLSession

    public init(
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        anthropicVersion: String = "2023-06-01",
        maxRetries: Int = 2,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.anthropicVersion = anthropicVersion
        self.maxRetries = max(0, maxRetries)
        self.session = session
    }

    public func complete(_ request: CloudAIRequest, apiKey: String) async throws -> CloudAIResponse {
        var attempt = 0
        while true {
            do {
                let urlRequest = try makeURLRequest(request, apiKey: apiKey, stream: false)
                let (data, response) = try await session.data(for: urlRequest)
                return try decodeResponse(data: data, response: response)
            } catch {
                guard attempt < maxRetries, shouldRetry(error) else {
                    throw error
                }
                attempt += 1
                try await Task.sleep(for: .milliseconds(150 * attempt))
            }
        }
    }

    public func stream(_ request: CloudAIRequest, apiKey: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeURLRequest(request, apiKey: apiKey, stream: true)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw CloudAIError.invalidResponse("Cloud AI returned a non-HTTP response.")
                    }
                    guard (200 ..< 300).contains(http.statusCode) else {
                        throw CloudAIError.transport(statusCode: http.statusCode, message: "Streaming request failed.")
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst("data: ".count))
                        if payload == "[DONE]" { break }
                        if let chunk = Self.textDelta(from: payload) {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeURLRequest(
        _ request: CloudAIRequest,
        apiKey: String,
        stream: Bool
    ) throws -> URLRequest {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")

        let body = AnthropicRequestBody(
            model: request.model,
            maxTokens: request.maxTokens,
            system: request.systemPrompt,
            messages: [
                AnthropicMessage(role: "user", content: request.userPrompt),
            ],
            stream: stream
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    private func decodeResponse(data: Data, response: URLResponse) throws -> CloudAIResponse {
        guard let http = response as? HTTPURLResponse else {
            throw CloudAIError.invalidResponse("Cloud AI returned a non-HTTP response.")
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(AnthropicErrorEnvelope.self, from: data).error.message)
                ?? String(data: data, encoding: .utf8)
                ?? ""
            throw CloudAIError.transport(statusCode: http.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(AnthropicMessageResponse.self, from: data)
        let text = decoded.content.compactMap(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw CloudAIError.emptyResponse
        }
        return CloudAIResponse(
            text: text,
            inputTokens: decoded.usage?.inputTokens ?? 0,
            outputTokens: decoded.usage?.outputTokens ?? 0,
            requestID: http.value(forHTTPHeaderField: "request-id") ?? decoded.id
        )
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        if case CloudAIError.transport(let status, _) = error {
            return status == 408 || status == 429 || (500 ..< 600).contains(status)
        }
        return (error as NSError).domain == NSURLErrorDomain
    }

    private static func textDelta(from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let event = try? JSONDecoder().decode(AnthropicStreamEvent.self, from: data),
              event.type == "content_block_delta",
              event.delta?.type == "text_delta"
        else {
            return nil
        }
        return event.delta?.text
    }
}

private struct AnthropicRequestBody: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [AnthropicMessage]
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case stream
    }
}

private struct AnthropicMessage: Encodable {
    let role: String
    let content: String
}

private struct AnthropicMessageResponse: Decodable {
    let id: String
    let content: [AnthropicContentBlock]
    let usage: AnthropicUsage?
}

private struct AnthropicContentBlock: Decodable {
    let type: String
    let text: String?
}

private struct AnthropicUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

private struct AnthropicErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}

private struct AnthropicStreamEvent: Decodable {
    struct Delta: Decodable {
        let type: String
        let text: String?
    }

    let type: String
    let delta: Delta?
}
