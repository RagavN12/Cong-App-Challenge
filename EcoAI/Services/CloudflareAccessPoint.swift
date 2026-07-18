import Foundation

struct CloudflareConfiguration: Sendable {
    let workerBaseURL: URL
    let streamTimeout: Duration

    static let preview = CloudflareConfiguration(
        workerBaseURL: URL(string: "https://example.workers.dev") ?? URL(fileURLWithPath: "/"),
        streamTimeout: .seconds(60)
    )
}

enum CloudflareAccessError: LocalizedError, Sendable {
    case streamTimedOut
    case invalidResponse
    case server(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .streamTimedOut: "The response took too long."
        case .invalidResponse: "The server returned an invalid response."
        case .server(let statusCode): "The server returned status \(statusCode)."
        }
    }
}

struct PreviewAccessTokenProvider: AccessTokenProviding {
    func accessToken(minTTL: Int) async throws -> String {
        "preview-token"
    }
}

/// Long-lived, concurrency-safe boundary for every Cloudflare Worker API.
/// Authentication and refresh-token state can be added here without exposing
/// mutable session data to SwiftUI views.
actor CloudflareAccessPoint {
    let configuration: CloudflareConfiguration

    private let tokenProvider: any AccessTokenProviding
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        configuration: CloudflareConfiguration,
        tokenProvider: any AccessTokenProviding
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .useDefaultKeys
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .useDefaultKeys
        self.decoder = decoder
    }

    /// Streams structured response events. This placeholder uses the same
    /// request and event types that the future SSE implementation will use.
    func streamAIResponse(
        request: LLMStreamRequest
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let timeout = configuration.streamTimeout

        return AsyncThrowingStream { continuation in
            let supervisor = Task {
                do {
                    try await withThrowingTaskGroup(of: Bool.self) { group in
                        group.addTask {
                            let response = "This is a preview response from EcoAI. When the Cloudflare Worker is connected, the assistant’s response will stream here in real time."
                            let chunks = response.split(separator: " ").map(String.init)

                            for (index, chunk) in chunks.enumerated() {
                                try Task.checkCancellation()
                                try await Task.sleep(for: .milliseconds(35))
                                continuation.yield(
                                    LLMStreamEvent(
                                        requestID: request.requestID,
                                        delta: (index == 0 ? "" : " ") + chunk,
                                        finishReason: index == chunks.indices.last ? "stop" : nil
                                    )
                                )
                            }
                            return true
                        }

                        group.addTask {
                            try await Task.sleep(for: timeout)
                            return false
                        }

                        guard let producerFinished = try await group.next() else {
                            throw CloudflareAccessError.invalidResponse
                        }
                        group.cancelAll()

                        if producerFinished {
                            continuation.finish()
                        } else {
                            throw CloudflareAccessError.streamTimedOut
                        }
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                supervisor.cancel()
            }
        }
    }

    /// Used by the real HTTP implementation to preserve a predictable JS wire format.
    func encodedRequest(_ request: LLMStreamRequest) throws -> Data {
        try encoder.encode(request)
    }

    func decodedEvent(from data: Data) throws -> LLMStreamEvent {
        try decoder.decode(LLMStreamEvent.self, from: data)
    }

    /// Creates a Worker request with a current Auth0 access token. Keeping this
    /// here ensures views and chat state never handle bearer tokens directly.
    func authorizedRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> URLRequest {
        let url = configuration.workerBaseURL.appending(path: path)
        let token = try await tokenProvider.accessToken(minTTL: 60)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}
