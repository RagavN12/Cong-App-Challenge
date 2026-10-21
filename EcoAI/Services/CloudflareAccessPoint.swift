import Foundation

struct CloudflareConfiguration: Sendable {
    let workerBaseURL: URL
    let streamTimeout: Duration

    static let preview = CloudflareConfiguration(
        workerBaseURL: URL(string: "https://ecoai-worker.fastflowcommons.workers.dev") ?? URL(fileURLWithPath: "/"),
        streamTimeout: .seconds(60)
    )

    /// Reads the deployed Worker's URL from Info.plist ("CloudflareWorkerURL"),
    /// e.g. https://ecoai-worker.<your-subdomain>.workers.dev — so the target
    /// can change per build without touching code. Falls back to `.preview`
    /// (which will surface CloudflareAccessError.invalidResponse) if unset.
    static func production(bundle: Bundle = .main) -> CloudflareConfiguration {
        guard
            let raw = bundle.object(forInfoDictionaryKey: "CloudflareWorkerURL") as? String,
            let url = URL(string: raw)
        else {
            return .preview
        }
        return CloudflareConfiguration(workerBaseURL: url, streamTimeout: .seconds(60))
    }
}

enum CloudflareAccessError: LocalizedError, Sendable {
    case streamTimedOut
    case invalidResponse
    case server(statusCode: Int)
    case provider(String, retryable: Bool)
    case interruptedResponse

    var errorDescription: String? {
        switch self {
        case .streamTimedOut: "The response took too long."
        case .invalidResponse: "The server returned an invalid response."
        case .server(let statusCode): "The server returned status \(statusCode)."
        case .provider(let message, _): message
        case .interruptedResponse: "The response ended before it was complete. Please try again."
        }
    }
}

protocol AccessTokenProviding: Sendable {
    func accessToken(minTTL: Int) async throws -> String
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
    private struct WorkerError: Decodable {
        let error: String?
        let detail: String?
        let upstream_status: Int?
    }
    let configuration: CloudflareConfiguration

    private let tokenProvider: any AccessTokenProviding
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let session: URLSession

    init(
        configuration: CloudflareConfiguration,
        tokenProvider: any AccessTokenProviding,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.session = session

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .useDefaultKeys
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .useDefaultKeys
        self.decoder = decoder
    }

    /// Streams the assistant's response from the Worker's `/v1/chat/stream`
    /// SSE endpoint. Each `data:` line is one JSON-encoded LLMStreamEvent;
    /// Usage may arrive after finish_reason, before the final [DONE] marker.
    func streamAIResponse(
        request: LLMStreamRequest
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        // Snapshot everything the background Task needs up front so the
        // closure below never has to hop back onto the actor.
        let encoder = self.encoder
        let decoder = self.decoder
        let tokenProvider = self.tokenProvider
        let baseURL = configuration.workerBaseURL
        let timeoutSeconds = TimeInterval(configuration.streamTimeout.components.seconds)
        let session = self.session

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let token = try await tokenProvider.accessToken(minTTL: 60)
                    try Task.checkCancellation()

                    var urlRequest = URLRequest(
                        url: baseURL.appending(path: "v1/chat/stream")
                    )
                    urlRequest.httpMethod = "POST"
                    urlRequest.httpBody = try encoder.encode(request)
                    urlRequest.timeoutInterval = timeoutSeconds
                    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let (bytes, response) = try await session.bytes(for: urlRequest)

                    guard let http = response as? HTTPURLResponse else {
                        throw CloudflareAccessError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // A gateway 502 can contain a permanent provider 400/402.
                        // Use the underlying status so retries do not repeat it.
                        var errorData = Data()
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            errorData.append(byte)
                            if errorData.count >= 8192 { break }
                        }
                        if let payload = try? decoder.decode(WorkerError.self, from: errorData),
                           let status = payload.upstream_status {
                            throw CloudflareAccessError.provider(
                                payload.detail ?? payload.error ?? "The provider rejected this request.",
                                retryable: ResponseRetryPolicy.isTransientStatus(status)
                            )
                        }
                        throw CloudflareAccessError.server(statusCode: http.statusCode)
                    }

                    var sawFinish = false
                    var sawDone = false
                    var hasContent = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }

                        let payload = line
                            .dropFirst("data:".count)
                            .trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            sawDone = true
                            break
                        }
                        guard let data = payload.data(using: .utf8) else { continue }

                        let event = try decoder.decode(LLMStreamEvent.self, from: data)
                        guard event.requestID == request.requestID else { continue }
                        if let error = event.error {
                            throw CloudflareAccessError.provider(error, retryable: event.retryable ?? false)
                        }
                        if event.finishReason == "error" {
                            throw CloudflareAccessError.provider("The provider could not finish this response.", retryable: event.retryable ?? false)
                        }
                        if event.finishReason != nil { sawFinish = true }
                        if !event.delta.isEmpty { hasContent = true }
                        continuation.yield(event)
                    }

                    try Task.checkCancellation()
                    guard sawFinish, sawDone, hasContent else {
                        throw CloudflareAccessError.interruptedResponse
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let urlError as URLError where urlError.code == .timedOut {
                    continuation.finish(throwing: CloudflareAccessError.streamTimedOut)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
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

    /// Creates a Worker request with a current Auth0 access token. Used for
    /// simple JSON endpoints like GET /v1/models; the streaming endpoint
    /// builds its own request in `streamAIResponse` above.
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
