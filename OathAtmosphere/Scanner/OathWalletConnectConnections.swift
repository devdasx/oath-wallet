import Foundation
import CryptoKit
import OathDiagnostics

/// Supplemental local lifecycle data only. Reown remains the source of session
/// metadata and encrypted keys. Legacy sessions have an unknown approval time;
/// expiry minus default TTL is not a valid substitute (sessions can extend).
struct OathWalletConnectConnections {
    private struct Entry: Codable {
        var connectedAt: Date?
        var revoked = false
        var activeChain: UInt64?
        var pairingIdentity: String?
    }
    private static let key = "walletconnect.connectionLifecycle.v1"
    private let defaults: UserDefaults
    private var entries: [String: Entry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = [:]
        guard let data = defaults.data(forKey: Self.key) else { return }
        do {
            guard data.count <= 65_536 else { throw DiagnosticFailure("Connection lifecycle storage exceeds limit") }
            let decoded = try JSONDecoder().decode([String: Entry].self, from: data)
            guard decoded.count <= 128, decoded.keys.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }),
                  decoded.values.allSatisfy({ ($0.connectedAt.map { $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 } ?? true) && ($0.activeChain.map { $0 > 0 } ?? true) && ($0.pairingIdentity.map { $0.count == 64 && $0.allSatisfy(\.isHexDigit) } ?? true) }) else {
                throw DiagnosticFailure("Invalid connection lifecycle storage")
            }
            entries = decoded
        } catch {
            OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                OathDiagnostics.record(error, component: "walletconnect", operation: "load_connection_lifecycle")
            }
        }
    }
    func connectedAt(_ topic: String) -> Date? { entries[Self.identity(topic)]?.connectedAt }
    func isRevoked(_ topic: String) -> Bool { entries[Self.identity(topic)]?.revoked == true }
    func activeChain(_ topic: String) -> UInt64? { entries[Self.identity(topic)]?.activeChain }
    func isAssociated(_ topic: String, with pairingTopic: String) -> Bool {
        guard let entry = entries[Self.identity(topic)], !entry.revoked else { return false }
        return entry.pairingIdentity == Self.identity(pairingTopic)
    }
    mutating func selectChain(_ chain: UInt64, for topic: String) {
        let key = Self.identity(topic)
        guard chain > 0, var entry = entries[key], !entry.revoked else { return }
        entry.activeChain = chain; entries[key] = entry; save()
    }

    mutating func approve(_ topic: String, pairingTopic: String? = nil, at date: Date = .now) {
        guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 > 0 else { return }
        let key = Self.identity(topic)
        guard entries[key] != nil || entries.count < 128 else { return }
        // The supported proposal supplies the association at consent time. Do
        // not depend on the SDK's deprecated Session.pairingTopic or persist it raw.
        entries[key] = Entry(connectedAt: entries[key]?.connectedAt ?? date, activeChain: entries[key]?.activeChain,
                             pairingIdentity: pairingTopic.map(Self.identity) ?? entries[key]?.pairingIdentity)
        save()
    }
    mutating func revoke(_ topic: String) {
        let key = Self.identity(topic)
        guard entries[key] != nil || entries.count < 128 else { return }
        entries[key] = Entry(connectedAt: entries[key]?.connectedAt, revoked: true)
        save()
    }
    mutating func reconcile(topics: Set<String>) {
        let retained = Set(topics.map(Self.identity))
        let next = entries.filter { retained.contains($0.key) }
        guard next.count != entries.count else { return }
        entries = next; save()
    }
    private func save() {
        do { defaults.set(try JSONEncoder().encode(entries), forKey: Self.key) }
        catch {
            OathDiagnostics.$operationID.withValue(OathDiagnostics.operationID ?? UUID()) {
                OathDiagnostics.record(error, component: "walletconnect", operation: "save_connection_lifecycle")
            }
        }
    }
    private static func identity(_ topic: String) -> String {
        SHA256.hash(data: Data(topic.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
