import Foundation

/// Only transient endpoint failures enter the retry loop. The original error
/// remains available for diagnostics and submission-outcome tracking.
struct SendTronRetryableFailure: Error {
    let underlying: Error
    var retryAfter: TimeInterval? = nil
    var submissionMayHaveSucceeded = false
}

enum SendTronRequestRetrier {
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    typealias Attempt<Value: Sendable> = @Sendable () async throws -> Value

    // Initial provider pass plus three retries. The first pause also clears
    // TronGrid's five-second suspension for unauthenticated rate limits.
    static let retryDelays: [TimeInterval] = [5, 10, 20]

    static func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    static func execute<Value: Sendable>(
        attempts: [Attempt<Value>],
        sleep: Sleep = Self.sleep
    ) async throws -> Value {
        guard !attempts.isEmpty else { throw URLError(.cannotFindHost) }
        var lastError: Error = URLError(.cannotConnectToHost)
        var uncertainSubmission: Error?
        for round in 0...retryDelays.count {
            var retryAfter: TimeInterval = 0
            for attempt in attempts {
                do {
                    try Task.checkCancellation()
                    return try await attempt()
                } catch let failure as SendTronRetryableFailure {
                    lastError = failure.underlying
                    if failure.submissionMayHaveSucceeded {
                        uncertainSubmission = failure.underlying
                    }
                    retryAfter = max(retryAfter, failure.retryAfter ?? 0)
                } catch {
                    // A later rejection cannot erase an earlier uncertain
                    // broadcast: retain the original transaction for monitoring.
                    throw uncertainSubmission ?? error
                }
            }
            guard round < retryDelays.count else { break }
            do {
                try await sleep(max(retryDelays[round], retryAfter))
            } catch {
                throw uncertainSubmission ?? error
            }
        }
        throw uncertainSubmission ?? lastError
    }

    static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)),
           seconds.isFinite, seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    static func isTemporary(code: String, message: String) -> Bool {
        let code = code.uppercased()
        if ["SERVER_BUSY", "NO_CONNECTION", "NOT_ENOUGH_EFFECTIVE_CONNECTION",
            "BLOCK_UNSOLIDIFIED", "OTHER_ERROR", "DUP_TRANSACTION_ERROR"].contains(code) {
            return true
        }
        let combined = (code + " " + message).lowercased()
        return code == "429" || code.contains("HTTP_429")
            || combined.contains("rate_limit") || combined.contains("rate limit")
            || combined.contains("rate exceeded") || combined.contains("allowed_rps")
            || combined.contains("too many requests") || combined.contains("server busy")
            || combined.contains("temporarily unavailable")
    }
}
