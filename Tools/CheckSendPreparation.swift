import Foundation

final class SendReadRecordingStorage: OathVaultStorage, @unchecked Sendable {
    private let base = WalletMemory()
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func read(_ account: String) throws -> Data? {
        lock.withLock { count += 1 }
        return try base.read(account)
    }
    func insert(_ data: Data, account: String) throws { try base.insert(data, account: account) }
    func update(_ data: Data, account: String) throws { try base.update(data, account: account) }
    func erase() throws { try base.erase() }
}

private actor SendPreparationGate {
    var arrivals = 0
    var finished = false
    private var released = false
    func wait() async throws {
        arrivals += 1
        while !released { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
    }
    func release() { released = true }
    func finish() { finished = true }
}

private enum PreparationFailure: Error { case rejected }
typealias SendPreparationOperation = @Sendable () async throws -> Void

/// Runs the production vault and shared preparation coordinator with gated
/// local fixtures. No elapsed-time guess substitutes for causal ordering.
@MainActor func checkSendPreparation(
    biometrics: MemoryBiometrics,
    storage: SendReadRecordingStorage,
    sign: @escaping @Sendable (@escaping SendPreparationOperation) async throws -> Void
) async throws -> Int {
    func check(_ condition: Bool, _ message: String = "Send preparation regression") { precondition(condition, message) }
    let gate = SendPreparationGate()
    let readsBeforePrompt = storage.reads
    await biometrics.pauseNextRead()
    let operation = Task {
        try await sign {
            try await OathSendPreparation.run(chain: "solana",
                reserve: { try await gate.wait() }, validate: { try await gate.wait() })
        }
        await gate.finish()
    }
    for _ in 0..<400 {
        if await biometrics.isWaiting, await gate.arrivals == 2 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    check(await biometrics.isWaiting, "Authentication must start before delayed preparation finishes")
    check(storage.reads == readsBeforePrompt, "Unlocked send must not read Keychain ahead of Face ID")
    check(await gate.arrivals == 2, "Reservation and validation must overlap authentication")
    await biometrics.releaseRead()
    // A successful authentication still cannot bypass pending preparation.
    try await Task.sleep(for: .milliseconds(50))
    check(await gate.finished == false, "Never sign before validation and reservation finish")
    await gate.release()
    try await operation.value
    check(await gate.finished, "Successful preparation may release exactly this signature")
    check(storage.reads > readsBeforePrompt, "The stored vault must still be re-read after authentication")

    let rejected = SendPreparationGate()
    await biometrics.failNextRead(.cancelled)
    do {
        try await sign { try await rejected.wait() }
        preconditionFailure("Cancelled authentication signed")
    } catch {
        precondition(error as? OathBiometricCredentialError == .cancelled)
    }
    // This call can finish only if structured cancellation stopped preparation.
    check(await rejected.finished == false)

    do {
        try await sign { throw PreparationFailure.rejected }
        preconditionFailure("Failed preparation signed")
    } catch { precondition(error is PreparationFailure) }

    let cancelled = SendPreparationGate()
    let pending = Task { try await sign { try await cancelled.wait() } }
    for _ in 0..<400 {
        if await cancelled.arrivals == 1 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    pending.cancel()
    do { try await pending.value; preconditionFailure("Cancelled send signed") }
    catch { precondition(error is CancellationError) }

    let saved = try storage.read("vault-v1")!
    await biometrics.pauseNextRead()
    let changed = Task { try await sign {} }
    for _ in 0..<400 {
        if await biometrics.isWaiting { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    check(await biometrics.isWaiting, "Stored-vault mutation test reached authentication")
    try storage.update(Data([0]), account: "vault-v1")
    await biometrics.releaseRead()
    do { try await changed.value; preconditionFailure("Cached envelope bypassed stored-vault validation") }
    catch { precondition(error is DecodingError) }
    try storage.update(saved, account: "vault-v1")
    return 12
}
