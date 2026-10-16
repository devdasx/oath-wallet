import Foundation

/// Shared across all four chains, quotes, submissions and recovery. An outage
/// must not fan out into a burst of retries against a rate-limited public API.
actor UTXOAPIBudget {
    static let shared = UTXOAPIBudget()
    struct Entry {
        var active = 0
        var next = ContinuousClock.now
        var blockedUntil = ContinuousClock.now
    }
    enum Deferred: Error { case cooldown, capacity }
    private var hosts: [String: Entry] = [:]

    private func bucket(_ host: String) -> String {
        // Four chain URLs share one Alchemy account allowance. At most two
        // active requests, spaced by 100ms (<=10 starts/s per app installation).
        AlchemyUTXOAPI.isHost(host) ? "alchemy" : host
    }

    func acquire(_ host: String) async throws {
        let host = bucket(host)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while true {
            try Task.checkCancellation()
            var entry = hosts[host] ?? Entry()
            let now = ContinuousClock.now
            guard entry.blockedUntil <= now else { throw Deferred.cooldown }
            if entry.active < 2, entry.next <= now {
                entry.active += 1
                let spacing: Duration = host == "api.blockchair.com" ? .milliseconds(1100)
                    : host == "api.blockcypher.com" ? .milliseconds(400) : .milliseconds(100)
                entry.next = now.advanced(by: spacing)
                // Only the fixed provider registry reaches this actor in app use.
                // Bound entries even if test/custom callers introduce new hosts.
                if hosts[host] == nil, hosts.count >= 32 { throw Deferred.capacity }
                hosts[host] = entry; return
            }
            guard now < deadline else { throw Deferred.capacity }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    func release(_ host: String) {
        let host = bucket(host)
        if var entry = hosts[host] { entry.active = max(0, entry.active - 1); hosts[host] = entry }
    }
    // Apply cooldown and release the slot in one actor turn. A queued caller
    // must not slip between releasing a response and observing its rate limit.
    func finish(_ host: String, statuses: [Int], retryAfter: String?) {
        for status in statuses { limit(host, status: status, retryAfter: retryAfter) }
        release(host)
    }
    func limit(_ host: String, status: Int, retryAfter: String?, now: Date = .now) {
        let host = bucket(host)
        guard [403, 429, 430].contains(status), var entry = hosts[host] else { return }
        var seconds = status == 430 ? 300.0 : 60.0
        if let retryAfter {
            if let delay = Double(retryAfter), delay.isFinite { seconds = max(seconds, delay) }
            else {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let date = formatter.date(from: retryAfter) { seconds = max(seconds, date.timeIntervalSince(now)) }
            }
        }
        entry.blockedUntil = .now.advanced(by: .seconds(min(seconds, 3600)))
        hosts[host] = entry
    }
}
