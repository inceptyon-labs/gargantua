import Foundation

/// `CloudAITransport` speaking the OpenAI Chat Completions wire format. Because
/// that shape is a de-facto standard, the same transport — pointed at a
/// configurable base URL — talks to OpenAI, OpenRouter, Groq, Together,
/// DeepSeek, Mistral, and local servers (Ollama, LM Studio, llama.cpp, vLLM).
///
/// Differences from `AnthropicMessagesTransport`: `Authorization: Bearer` auth
/// (omitted when the key is empty, for local servers that don't need one), the
/// system prompt rides as a `system` message, and the response text comes from
/// `choices[0].message.content` with `prompt_tokens`/`completion_tokens` usage.
public struct OpenAIChatCompletionsTransport: CloudAITransport {
    public let baseURL: URL
    public let maxRetries: Int
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        maxRetries: Int = 2,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
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
                guard attempt < maxRetries, shouldRetry(error) else { throw error }
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

    private var endpoint: URL {
        baseURL.appendingPathComponent("chat/completions")
    }

    private func makeURLRequest(
        _ request: CloudAIRequest,
        apiKey: String,
        stream: Bool
    ) throws -> URLRequest {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            urlRequest.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        let body = OpenAIRequestBody(
            model: request.model,
            maxTokens: request.maxTokens,
            messages: [
                OpenAIMessage(role: "system", content: request.systemPrompt),
                OpenAIMessage(role: "user", content: request.userPrompt),
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
            let message = (try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data).error.message)
                ?? String(data: data, encoding: .utf8)
                ?? ""
            throw CloudAIError.transport(statusCode: http.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        let text = (decoded.choices.first?.message.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw CloudAIError.emptyResponse
        }
        return CloudAIResponse(
            text: text,
            inputTokens: decoded.usage?.promptTokens ?? 0,
            outputTokens: decoded.usage?.completionTokens ?? 0,
            requestID: http.value(forHTTPHeaderField: "x-request-id") ?? decoded.id
        )
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if case CloudAIError.transport(let status, _) = error {
            return status == 408 || status == 429 || (500 ..< 600).contains(status)
        }
        return (error as NSError).domain == NSURLErrorDomain
    }

    private static func textDelta(from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let event = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data)
        else {
            return nil
        }
        return event.choices.first?.delta.content
    }
}

/// Builds the right transport for the configured provider. The service resolves
/// this per request so changing provider/base URL in Settings takes effect
/// immediately.
public enum CloudAITransportFactory {
    public static func make(for configuration: CloudAIConfiguration, session: URLSession = .shared) -> any CloudAITransport {
        switch configuration.provider {
        case .anthropic:
            return AnthropicMessagesTransport(session: session)
        case .openAICompatible:
            // Fail closed: a non-empty but unparseable base URL must NOT silently
            // route paths + file snippets to api.openai.com. (Empty resolves to
            // OpenAI's default, which is the intended convenience.)
            guard let base = configuration.resolvedOpenAIBaseURL else {
                return FailingCloudAITransport(
                    error: .invalidResponse("The OpenAI-compatible base URL isn't a valid URL: \(configuration.openAIBaseURL)")
                )
            }
            return OpenAIChatCompletionsTransport(baseURL: base, session: session)
        }
    }
}

/// A transport that always throws. Used when the configuration is invalid (e.g.
/// an unparseable base URL), so requests fail with a clear error instead of
/// being silently sent somewhere unexpected.
public struct FailingCloudAITransport: CloudAITransport {
    public let error: CloudAIError

    public init(error: CloudAIError) { self.error = error }

    public func complete(_ request: CloudAIRequest, apiKey: String) async throws -> CloudAIResponse {
        throw error
    }
}

private struct OpenAIRequestBody: Encodable {
    let model: String
    let maxTokens: Int
    let messages: [OpenAIMessage]
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case messages
        case stream
    }
}

private struct OpenAIMessage: Encodable {
    let role: String
    let content: String
}

private struct OpenAIChatResponse: Decodable {
    let id: String?
    let choices: [OpenAIChoice]
    let usage: OpenAIUsage?
}

private struct OpenAIChoice: Decodable {
    let message: OpenAIResponseMessage
}

private struct OpenAIResponseMessage: Decodable {
    let content: String?
}

private struct OpenAIUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}

private struct OpenAIErrorEnvelope: Decodable {
    struct APIError: Decodable { let message: String }
    let error: APIError
}

private struct OpenAIStreamChunk: Decodable {
    let choices: [OpenAIStreamChoice]
}

private struct OpenAIStreamChoice: Decodable {
    let delta: OpenAIStreamDelta
}

private struct OpenAIStreamDelta: Decodable {
    let content: String?
}
