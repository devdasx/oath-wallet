import Foundation

private enum Failure: Error, Equatable {
    case temporary(Int), terminal, uncertain
}

private actor Probe {
    var calls: [Int] = []
    var delays: [TimeInterval] = []

    func record(_ provider: Int) -> Int {
        calls.append(provider)
        return calls.count
    }

    func pause(_ seconds: TimeInterval) { delays.append(seconds) }
}

@main
private struct Regression {
    static func main() async throws {
        // Fallback is immediate and stops after the first successful provider.
        let fallback = Probe()
        let value: Int = try await SendTronRequestRetrier.execute(attempts: [
            {
                _ = await fallback.record(0)
                throw SendTronRetryableFailure(underlying: Failure.temporary(0))
            },
            { _ = await fallback.record(1); return 42 },
            { _ = await fallback.record(2); return 0 }
        ], sleep: { await fallback.pause($0) })
        precondition(value == 42)
        let fallbackCalls = await fallback.calls
        let fallbackDelays = await fallback.delays
        precondition(fallbackCalls == [0, 1] && fallbackDelays.isEmpty)

        // Every provider gets the initial attempt plus three delayed retries.
        let exhausted = Probe()
        let attempts: [SendTronRequestRetrier.Attempt<Int>] = (0..<3).map { provider in
            {
                _ = await exhausted.record(provider)
                throw SendTronRetryableFailure(underlying: Failure.temporary(provider))
            }
        }
        do {
            _ = try await SendTronRequestRetrier.execute(
                attempts: attempts, sleep: { await exhausted.pause($0) }
            )
            preconditionFailure("Temporary failures must exhaust the budget.")
        } catch { precondition(error as? Failure == .temporary(2)) }
        let exhaustedCalls = await exhausted.calls
        let exhaustedDelays = await exhausted.delays
        precondition(exhaustedCalls == Array(repeating: [0, 1, 2], count: 4).flatMap { $0 })
        precondition(exhaustedDelays == [5, 10, 20])

        // Retry-After wins when it is longer than the normal backoff.
        let recovery = Probe()
        let recovered: Int = try await SendTronRequestRetrier.execute(attempts: [{
            if await recovery.record(0) == 1 {
                throw SendTronRetryableFailure(underlying: Failure.temporary(0), retryAfter: 12)
            }
            return 7
        }], sleep: { await recovery.pause($0) })
        let recoveryDelays = await recovery.delays
        precondition(recovered == 7 && recoveryDelays == [12])

        // Invalid requests or signatures must not be repeatedly submitted.
        let rejected = Probe()
        do {
            let _: Int = try await SendTronRequestRetrier.execute(attempts: [{
                _ = await rejected.record(0)
                throw Failure.terminal
            }, { _ = await rejected.record(1); return 1 }], sleep: { await rejected.pause($0) })
            preconditionFailure("Terminal rejection must stop.")
        } catch { precondition(error as? Failure == .terminal) }
        let rejectedCalls = await rejected.calls
        let rejectedDelays = await rejected.delays
        precondition(rejectedCalls == [0] && rejectedDelays.isEmpty)

        // A later explicit rejection must not turn an earlier timeout into
        // permission to construct and send another payment.
        do {
            let _: Int = try await SendTronRequestRetrier.execute(attempts: [{
                throw SendTronRetryableFailure(
                    underlying: Failure.uncertain, submissionMayHaveSucceeded: true
                )
            }, { throw Failure.terminal }], sleep: { _ in })
            preconditionFailure("Uncertain receipt must survive.")
        } catch { precondition(error as? Failure == .uncertain) }

        // Cancellation ends the backoff immediately; a broadcast still stays
        // uncertain, while a read remains a regular cancellation.
        for broadcast in [false, true] {
            let cancelled = Probe()
            do {
                let _: Int = try await SendTronRequestRetrier.execute(attempts: [{
                    _ = await cancelled.record(0)
                    throw SendTronRetryableFailure(
                        underlying: Failure.uncertain, submissionMayHaveSucceeded: broadcast
                    )
                }], sleep: { _ in throw CancellationError() })
                preconditionFailure("Cancellation must stop retries.")
            } catch {
                if broadcast { precondition(error as? Failure == .uncertain) }
                else { precondition(error is CancellationError) }
            }
            let calls = await cancelled.calls
            precondition(calls == [0])
        }

        let now = Date(timeIntervalSince1970: 0)
        for (header, expected) in [
            ("8", Optional(8.0)), ("-1", nil), ("invalid", nil),
            ("Thu, 01 Jan 1970 00:00:15 GMT", Optional(15.0)), ("nan", nil)
        ] {
            let response = HTTPURLResponse(
                url: URL(string: "https://example.invalid")!, statusCode: 429,
                httpVersion: "HTTP/1.1", headerFields: ["Retry-After": header]
            )!
            precondition(SendTronRequestRetrier.retryAfter(response, now: now) == expected)
        }
        for code in ["SERVER_BUSY", "server_busy", "NO_CONNECTION", "DUP_TRANSACTION_ERROR", "http_429_http_429"] {
            precondition(SendTronRequestRetrier.isTemporary(code: code, message: ""))
        }
        precondition(SendTronRequestRetrier.isTemporary(
            code: "provider_error", message: "request rate exceeded the allowed_rps(3)"
        ))
        for code in ["SIGERROR", "CONTRACT_VALIDATE_ERROR", "TRANSACTION_EXPIRATION_ERROR"] {
            precondition(!SendTronRequestRetrier.isTemporary(code: code, message: "Rejected"))
        }
        print("Passed TRON retry regressions: fallback, three retries, backoff, Retry-After, recovery, terminal errors, uncertainty, cancellation, and temporary-error classification.")
    }
}
