import Foundation
import OathDatabase
import OathAnkr

private final class BatchClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func expire() { lock.withLock { instant = instant.advanced(by: .seconds(1_801)) } }
}
private actor BatchPreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private typealias BatchSign = @Sendable (UUID, @escaping @Sendable () async throws -> Void) async throws -> Void

/// Production vault, local SQL and imported-key signers; synthetic credentials.
/// The clock advances grant lifetime without aging the fresh transaction plan.
@main struct CheckPermissionBatchRaces {
    @MainActor static func main() async throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: \(name)") }
        }
        for chain in [OathImportChain.arbitrum, .tron, .solana] {
            for action in ["valid", "unrelated-end", "end", "replace", "expire", "lock", "cancel"] {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BatchRace-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: folder) }
                let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
                try await OathDataEnvironment.seed(db)
                let clock = BatchClock()
                let vault = OathWalletVault(storage: WalletMemory(), biometricStore: MemoryBiometrics(), database: db, permissionClock: { clock.now() })
                let pin: [UInt8] = [1,2,3,4,5,6]
                try await vault.create(digits: pin, importing: nil, privateKey: .init(bytes: Data(repeating: 7, count: 32), networks: [chain]))
                let profile = try await vault.unlockedProfile()
                let account = try await db.accounts(walletID: profile.id.uuidString).first!
                let id = UUID().uuidString, walletID = profile.id.uuidString
                let now = Date.now.timeIntervalSince1970
                let asset = account.networkID + ":native"
                let scope: PermissionBatchScope
                let sign: BatchSign
                switch chain {
                case .arbitrum:
                    let recipient = try EVMSendCrypto.address(privateKey: Data(repeating: 8, count: 32))
                    let plan = EVMSendPlan(network: .arbitrum, sender: account.address.lowercased(), recipient: recipient,
                        reference: "native", decimals: 18, requestedAmount: "0", amount: "0", assetBalance: "1000000000000000000",
                        nativeBalance: "1000000000000000000", nonce: 0, gasLimit: 70_000, maxFeePerGas: 41_000_000_000,
                        maxPriorityFeePerGas: 1_000_000_000, blockHeight: 100,
                        removal: .init(kind: .token, contract: recipient, spender: "0x" + String(repeating: "3", count: 40), expected: "123"))
                    let quote = OathEVMQuote(walletID: walletID, accountID: account.id, assetID: asset, plan: plan)
                    try await db.saveDraft(.init(id: id, walletID: walletID, accountID: account.id, networkID: account.networkID,
                        assetID: asset, idempotencyKey: id, recipient: recipient, amountAtomic: "0", state: "draft", createdAt: now, updatedAt: now))
                    try await db.queueEVMSend(sendID: id, plan: plan)
                    scope = try .evm(sendID: id, walletID: walletID, accountID: account.id, plan: plan)
                    sign = { grant, prepare in
                        let signed = try await vault.signEVMSend(sendID: id, quote: quote, digits: nil, reason: "", permissionAuthorization: grant, prepare: prepare)
                        try EVMSendCrypto.verify(signed, plan: plan)
                    }
                case .tron:
                    let recipient = try TronSendCrypto.address(privateKey: Data(repeating: 8, count: 32)), ms = UInt64(now * 1_000)
                    let plan = TronSendPlan(network: .mainnet, sender: account.address, recipient: recipient, reference: "native",
                        amount: "0", requestedAmount: "0", assetBalance: "100000000", decimals: 6, nativeBalance: 100000000,
                        fee: 1_000, estimatedFee: 100, feeLimit: 1_000_000, energyPrice: 100, bandwidthPrice: 1_000,
                        blockID: "0000000000000064" + String(repeating: "a", count: 48), blockNumber: 100,
                        timestamp: ms, expiration: ms + 180_000, removal: .init(contract: recipient, spender: account.address, expected: "123"))
                    let quote = OathTronQuote(walletID: walletID, accountID: account.id, assetID: asset, plan: plan)
                    try await db.saveDraft(.init(id: id, walletID: walletID, accountID: account.id, networkID: account.networkID,
                        assetID: asset, idempotencyKey: id, recipient: recipient, amountAtomic: "0", state: "draft", createdAt: now, updatedAt: now))
                    try await db.queueTronSend(sendID: id, plan: plan)
                    scope = try .tron(sendID: id, walletID: walletID, accountID: account.id, plan: plan)
                    sign = { grant, prepare in
                        let signed = try await vault.signTronSend(sendID: id, quote: quote, digits: nil, reason: "", permissionAuthorization: grant, prepare: prepare)
                        try TronSendCrypto.verify(signed, plan: plan)
                    }
                case .solana:
                    let recipient = try SolanaSendCrypto.address(privateKey: Data(repeating: 8, count: 32))
                    let plan = SolanaSendPlan(network: .mainnet, sender: account.address, recipient: recipient,
                        requestedAmount: 0, amount: 0, assetBalance: 100_000_000, nativeBalance: 100_000_000,
                        blockhash: SolanaSendCrypto.encode(Data(repeating: 3, count: 32)), lastValidBlockHeight: 100, slot: 10,
                        transactionFee: 5_000, removal: .init(account: recipient, mint: SolanaSendCrypto.encode(Data(repeating: 3, count: 32)),
                            program: SolanaIdentity.tokenProgram, delegate: SolanaSendCrypto.encode(Data(repeating: 4, count: 32)), amount: 123))
                    let quote = OathSolanaQuote(walletID: walletID, accountID: account.id, assetID: asset, plan: plan)
                    try await db.saveDraft(.init(id: id, walletID: walletID, accountID: account.id, networkID: account.networkID,
                        assetID: asset, idempotencyKey: id, recipient: recipient, amountAtomic: "0", state: "draft", createdAt: now, updatedAt: now))
                    try await db.queueSolanaSend(sendID: id, plan: plan)
                    scope = try .solana(sendID: id, walletID: walletID, accountID: account.id, plan: plan)
                    sign = { grant, prepare in
                        let signed = try await vault.signSolanaSend(sendID: id, quote: quote, digits: nil, reason: "", permissionAuthorization: grant, prepare: prepare)
                        try SolanaSendCrypto.verify(signed, plan: plan)
                    }
                default: fatalError("Unexpected synthetic chain")
                }
                let grant = try await vault.authorizePermissionBatch([scope], digits: pin, reason: "Test")
                let gate = BatchPreparationGate()
                let pending = Task { try await sign(grant) { await gate.wait() } }
                for _ in 0..<400 {
                    if await gate.entered { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard await gate.entered else { fatalError("Preparation gate not entered") }
                // The vault actor barrier and rejected replay establish that the
                // original item was consumed before revocation, not merely queued.
                check(await vault.permissionBatchIsAuthorized(grant), "\(account.networkID)/\(action): grant current while preparation held")
                do { try await sign(grant) {}; check(false, "\(account.networkID)/\(action): replay unexpectedly signed") }
                catch { check(error as? PermissionError == .changed, "\(account.networkID)/\(action): item consumed before mutation") }
                switch action {
                case "end": await vault.endPermissionBatch(grant)
                case "unrelated-end": await vault.endPermissionBatch(UUID())
                case "replace": _ = try await vault.authorizePermissionBatch([scope], digits: pin, reason: "Replacement")
                case "expire": clock.expire()
                case "lock": await vault.lock()
                case "cancel": pending.cancel()
                default: break
                }
                await gate.release()
                let expectedSuccess = action == "valid" || action == "unrelated-end"
                do {
                    try await pending.value
                    check(expectedSuccess, "\(account.networkID)/\(action): revoked grant produced a signature")
                } catch {
                    let expected = !expectedSuccess && (error is CancellationError || error as? PermissionError == .changed)
                    check(expected, "\(account.networkID)/\(action): unexpected rejection \(type(of: error))")
                }
                let row = try await db.send(id)
                check(row?.signedPayload == nil, "\(account.networkID)/\(action): no journal write or broadcast")
            }
        }
        print("BATCH_RACES checks=\(checks) failures=\(failures) scenarios=21 chains=3")
        if failures != 0 { exit(1) }
    }
}
