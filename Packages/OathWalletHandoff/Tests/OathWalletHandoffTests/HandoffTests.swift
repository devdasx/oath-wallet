import Foundation
import Testing
@testable import OathWalletHandoff

@Test(arguments: ["electrumOld", "electrumStandard", "electrumSegwit", "electrumTwoFactor", "electrumTwoFactorSegwit", "aezeed"])
func bitcoinMnemonicHandoffPreservesSchemeAndRejectsDowngrade(_ scheme: String) async throws {
    let storage = MemoryStorage(), now = Date()
    let mailbox = HandoffMailbox(storage: storage)
    let source = WalletHandoff(kind: .recoveryPhrase, value: "public mnemonic fixture", passphrase: " e\u{301} 🔐 ",
        importNetworkID: "bitcoin", accounts: [.init(networkID: "bitcoin", address: "fixture-address", derivationPath: "m/0/0")], recoveryScheme: scheme)
    let ref = try await mailbox.publish(source, now: now)
    let stored = try storage.take(id: ref.id)
    let data = try #require(stored)
    var envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(envelope["version"] as? Int == 2)
    try storage.put(data, id: ref.id)
    let restored = try await mailbox.consume(ref, now: now)
    #expect(restored.recoveryScheme == scheme)
    #expect(restored.passphrase?.utf8.elementsEqual(source.passphrase!.utf8) == true)
    envelope["version"] = 1
    try storage.put(JSONSerialization.data(withJSONObject: envelope), id: ref.id)
    await #expect(throws: HandoffError.invalid) { try await mailbox.consume(ref, now: now) }
    let wrongChain = WalletHandoff(kind: .recoveryPhrase, value: source.value, accounts: [.init(networkID: "ethereum", address: "fixture", derivationPath: "m/0")], recoveryScheme: scheme)
    #expect(throws: HandoffError.invalid) { try wrongChain.validate() }
}

private final class MemoryStorage: HandoffStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Data] = [:]
    var failWrites = false
    func put(_ data: Data, id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw HandoffError.unavailable }
        values = [id: data]
    }
    func take(id: UUID) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values.removeValue(forKey: id)
    }
    func remove(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: id)
    }
}
private func payload(_ kind: WalletHandoff.Kind = .recoveryPhrase) -> WalletHandoff {
    .init(kind: kind, value: kind == .recoveryPhrase ? "public recovery fixture" : "",
          rawKey: kind == .privateKey ? Data(repeating: 7, count: 32) : nil,
          passphrase: kind == .recoveryPhrase ? " public CASE-sensitive passphrase " : nil,
          importNetworkID: kind == .privateKey ? "solana" : nil,
          accounts: [.init(networkID: "solana", address: "public-account", derivationPath: "m/44'/501'/0'/0'")])
}
@Test func referenceRoundTripNeverContainsRecoveryMaterial() throws {
    let ref = HandoffReference()
    #expect(HandoffReference(url: ref.url) == ref)
    let parts = try #require(URLComponents(url: ref.url, resolvingAgainstBaseURL: false))
    #expect(Set(parts.queryItems!.map(\.name)) == ["v", "id"])
    #expect(ref.url.absoluteString.count < 100)
}
@Test(arguments: ["oathwallet://vault-import?v=1&id=ID", "https://oathwallet.org?v=1&id=ID",
    "oathwallet-import-v1://wallet/extra?v=1&id=ID", "oathwallet-import-v1://wallet?v=2&id=ID",
    "oathwallet-import-v1://wallet?v=1&id=ID&id=ID", "oathwallet-import-v1://wallet?v=1&id=ID&secret=bad",
    "oathwallet-import-v1://wallet?v=1&id=ID#fragment", "oathwallet-import-v1://other?v=1&id=ID",
    "oathwallet-import-v1://user@wallet?v=1&id=ID", "oathwallet-import-v1://wallet:4?v=1&id=ID"])
func rejectsUntrustedLinks(_ raw: String) {
    let url = URL(string: raw.replacingOccurrences(of: "ID", with: UUID().uuidString))!
    #expect(HandoffReference(url: url) == nil)
}
@Test(arguments: [WalletHandoff.Kind.recoveryPhrase, .privateKey])
func roundTripPreservesMaterialAndChain(_ kind: WalletHandoff.Kind) async throws {
    let mailbox = HandoffMailbox(storage: MemoryStorage()); let original = payload(kind)
    let ref = try await mailbox.publish(original)
    let received = try await mailbox.consume(ref)
    #expect(received.kind == original.kind)
    #expect(received.value == original.value)
    #expect(received.rawKey == original.rawKey)
    #expect(received.passphrase == original.passphrase)
    #expect(received.importNetworkID == original.importNetworkID)
    #expect(received.accounts == original.accounts)
    await #expect(throws: HandoffError.unavailable) { try await mailbox.consume(ref) }
}
@Test func expiredTransferIsDeleted() async throws {
    let mailbox = HandoffMailbox(storage: MemoryStorage()); let now = Date()
    let ref = try await mailbox.publish(payload(), now: now)
    await #expect(throws: HandoffError.expired) { try await mailbox.consume(ref, now: now.addingTimeInterval(300)) }
    await #expect(throws: HandoffError.unavailable) { try await mailbox.consume(ref, now: now) }
}
@Test func clockRollbackCannotExtendLifetime() async throws {
    let mailbox = HandoffMailbox(storage: MemoryStorage()); let now = Date()
    let ref = try await mailbox.publish(payload(), now: now)
    await #expect(throws: HandoffError.expired) { try await mailbox.consume(ref, now: now.addingTimeInterval(-10)) }
}
@Test func newTransferReplacesAbandonedTransfer() async throws {
    let mailbox = HandoffMailbox(storage: MemoryStorage())
    let first = try await mailbox.publish(payload()); let second = try await mailbox.publish(payload(.privateKey))
    await #expect(throws: HandoffError.unavailable) { try await mailbox.consume(first) }
    #expect(try await mailbox.consume(second).kind == .privateKey)
}
@Test func failedOpenCanRevokeTransfer() async throws {
    let mailbox = HandoffMailbox(storage: MemoryStorage()); let ref = try await mailbox.publish(payload())
    try await mailbox.discard(ref)
    await #expect(throws: HandoffError.unavailable) { try await mailbox.consume(ref) }
}
@Test func simultaneousReceiversHaveOnlyOneWinner() async throws {
    let storage = MemoryStorage(); let sender = HandoffMailbox(storage: storage)
    let ref = try await sender.publish(payload())
    let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for _ in 0..<20 { group.addTask { (try? await HandoffMailbox(storage: storage).consume(ref)) != nil } }
        var count = 0; for await result in group { if result { count += 1 } }; return count
    }
    #expect(winners == 1)
}
@Test func invalidEnvelopeCannotBeRetriedOrReadAsMaterial() async throws {
    let storage = MemoryStorage(); let ref = HandoffReference()
    try storage.put(Data("invalid".utf8), id: ref.id)
    let mailbox = HandoffMailbox(storage: storage)
    await #expect(throws: HandoffError.invalid) { try await mailbox.consume(ref) }
    await #expect(throws: HandoffError.unavailable) { try await mailbox.consume(ref) }
}
@Test func writeFailureNeverReturnsAReference() async throws {
    let storage = MemoryStorage(); storage.failWrites = true
    await #expect(throws: HandoffError.unavailable) { try await HandoffMailbox(storage: storage).publish(payload()) }
}
@Test func malformedKeyAndAmbiguousAccountsAreRejected() throws {
    let account = WalletHandoff.Account(networkID: "eth", address: "public", derivationPath: "imported")
    #expect(throws: HandoffError.invalid) { try WalletHandoff(kind: .privateKey, value: "", rawKey: Data(count: 31), accounts: [account]).validate() }
    #expect(throws: HandoffError.invalid) { try WalletHandoff(kind: .privateKey, value: "key", passphrase: "wrong", accounts: [account]).validate() }
    #expect(throws: HandoffError.invalid) { try WalletHandoff(kind: .recoveryPhrase, value: "phrase", accounts: [account, account]).validate() }
    #expect(throws: HandoffError.invalid) { try WalletHandoff(kind: .recoveryPhrase, value: String(repeating: "x", count: 32769), accounts: [account]).validate() }
}
