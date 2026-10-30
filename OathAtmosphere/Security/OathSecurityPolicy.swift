import Foundation

struct OathWalletSecurityState: Equatable, Sendable {
    var passcodeEnabled = true
    var biometricsEnabled = false
}

enum OathLockDelay: Int, CaseIterable, Sendable {
    case immediately = 0, oneMinute = 60, fiveMinutes = 300, tenMinutes = 600
    static let settingKey = "security.lockDelay"
    init(settings: [String: String]) {
        self = settings[Self.settingKey].flatMap(Int.init).flatMap(Self.init(rawValue:)) ?? .immediately
    }
}

/// The continuous clock counts device sleep and cannot be extended by changing
/// the wall clock. Unlike an awake-time counter, it expires while iOS sleeps.
/// A cold launch has no grace period: only this process's unlocked session does.
struct OathAutoLockPolicy: Sendable {
    private(set) var deadline: ContinuousClock.Instant?
    mutating func leave(delay: OathLockDelay, now: ContinuousClock.Instant) {
        if deadline == nil { deadline = now.advanced(by: .seconds(delay.rawValue)) }
    }
    func requiresLock(now: ContinuousClock.Instant) -> Bool { deadline.map { now >= $0 } ?? false }
    mutating func reset() { deadline = nil }
}
