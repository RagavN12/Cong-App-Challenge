import Foundation

nonisolated struct ResponseRetryPolicy: Sendable {
    let maximumAttempts: Int
    let initialDelay: Duration
    let maximumDelay: Duration

    static let standard = ResponseRetryPolicy(
        maximumAttempts: 10, initialDelay: .milliseconds(500), maximumDelay: .seconds(3)
    )
    static let none = ResponseRetryPolicy(
        maximumAttempts: 1, initialDelay: .zero, maximumDelay: .zero
    )

    func delay(after attempt: Int) -> Duration {
        min(initialDelay * (1 << min(max(attempt - 1, 0), 4)), maximumDelay)
    }

    func shouldRetry(_ error: Error) -> Bool {
        if let error = error as? CloudflareAccessError {
            switch error {
            case .streamTimedOut, .interruptedResponse: return true
            case .server(let code): return Self.isTransientStatus(code)
            case .provider(_, let retryable): return retryable
            case .invalidResponse: return false
            }
        }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet].contains(error.code)
        }
        return false
    }

    static func isTransientStatus(_ code: Int) -> Bool {
        code == 408 || code == 429 || (500...599).contains(code)
    }
}
