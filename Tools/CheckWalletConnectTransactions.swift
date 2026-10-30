import Foundation
import OathAnkr
import OathDatabase

/// Production submission owner, vault and durable journal, with a deterministic
/// RPC transport. No real wallet, relay, network, simulator or device is used.
private actor TransactionRPC: AnkrTransport {
    var broadcasts = 0
    var nonce: UInt64 = 7
    var confirmedPlan: EVMSendPlan?
    var confirmedHash: String?
    var finalizedHeight: UInt64 = 100
    func advanceNonce() { nonce += 1 }
    func confirm(plan: EVMSendPlan, hash: String, finalized: UInt64 = 100) { confirmedPlan = plan; confirmedHash = hash; finalizedHeight = finalized }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let root = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
        func reply(_ body: SolanaJSON) throws -> SolanaJSON {
            let result: SolanaJSON
            switch body["method"].string {
            case "eth_chainId": result = .string("0x1")
            case "eth_getBlockByNumber": result = .object(["number": .string("0x" + String(body["params"].array?.first?.string == "finalized" ? finalizedHeight : 100, radix: 16)), "hash": .string("0x" + String(repeating: "a", count: 64)), "timestamp": .string("0x" + String(UInt64(Date.now.timeIntervalSince1970), radix: 16)), "baseFeePerGas": .string("0x1dcd6500")])
            case "eth_getBalance": result = .string("0xde0b6b3a7640000")
            case "eth_getTransactionCount": result = .string("0x" + String(nonce, radix: 16))
            case "eth_gasPrice": result = .string("0x3b9aca00")
            case "eth_estimateGas": result = .string("0xea60")
            case "eth_call":
                let data=body["params"].array?.first?["data"].string ?? ""
                result = .string(data=="0x313ce567" ? "0x6":data.hasPrefix("0x70a08231") ? "0xf4240":"0x" + String(repeating: "0", count: 63) + "1")
            case "eth_sendRawTransaction":
                broadcasts += 1
                let raw = body["params"].array![0].string!
                result = .string("0x" + TronSendCrypto.keccak(try TronIdentity.hex(String(raw.dropFirst(2)))).map { String(format: "%02x", $0) }.joined())
            case "eth_getTransactionReceipt":
                if let plan = confirmedPlan, let hash = confirmedHash {
                    result = .object(["transactionHash": .string(hash), "from": .string(plan.sender), "to": .string(plan.receiver),
                        "blockNumber": .string("0x64"), "blockHash": .string("0x" + String(repeating: "a", count: 64)),
                        "gasUsed": .string("0x5208"), "effectiveGasPrice": .string("0x3b9aca00"), "status": .string("0x1"), "logs": .array([])])
                } else { result = .null }
            case "eth_getTransactionByHash":
                if let plan = confirmedPlan, let hash = confirmedHash {
                    result = .object(["hash": .string(hash), "from": .string(plan.sender), "to": .string(plan.receiver),
                        "chainId": .string("0x1"), "type": .string("0x2"), "nonce": .string("0x" + String(plan.nonce, radix: 16)),
                        "gas": .string("0x" + String(plan.gasLimit, radix: 16)), "value": .string(try EVMSendAmount.hex(plan.value)), "input": .string("0x" + (try EVMSendCrypto.data(plan)).map { String(format: "%02x", $0) }.joined()),
                        "maxFeePerGas": .string("0x" + String(plan.maxFeePerGas, radix: 16)),
                        "maxPriorityFeePerGas": .string("0x" + String(plan.maxPriorityFeePerGas, radix: 16)),
                        "blockNumber": .string("0x64"), "blockHash": .string("0x" + String(repeating: "a", count: 64))])
                } else { result = .null }
            default: throw EVMSendError.configuration
            }
            return .object(["jsonrpc": .string("2.0"), "id": body["id"], "result": result])
        }
        return (try JSONEncoder().encode(root.array.map { try .array($0.map(reply)) } ?? reply(root)), 200)
    }
}
private actor AuthorizationGate {
    private var calls = 0
    let invalidAt: Int
    init(invalidAt: Int = .max) { self.invalidAt = invalidAt }
    func validate() throws { calls += 1; if calls >= invalidAt { throw CancellationError() } }
}
@main struct CheckWalletConnectTransactions {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ why: String) { precondition(condition, why); checks += 1 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WalletConnectTransactions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let vault = OathWalletVault(storage: WalletMemory(), biometricStore: MemoryBiometrics(), database: db)
        let pin: [UInt8] = [1,2,3,4,5,6]
        try await vault.create(digits: pin, importing: nil, privateKey: .init(bytes: Data(repeating: 1, count: 32), networks: [.ethereum]))
        let profile = try await vault.unlockedProfile()
        let account = try await db.accounts(walletID: profile.id.uuidString).first!
        let rpc = TransactionRPC()
        let client = try EVMSendClient(network: .ethereum, endpoints: [URL(string: "https://fixture.invalid")!], transport: rpc)
        let service = OathEVMSendService(clients: [.ethereum: client])
        let id = "wc:" + String(repeating: "a", count: 64)
        let body: [[String: String]] = [["from": account.address, "to": "0x" + String(repeating: "2", count: 40), "value": "0x1", "data": "0x"]]
        let input = try WalletConnectEVMRequest(params: JSONEncoder().encode(body), account: account.address, chainID: 1)
        let quote = try await service.walletConnectQuote(input, requestID: id, walletID: profile.id.uuidString, accountID: account.id, vault: vault)
        check(input.matches(quote.plan), "Quote preserves exact request")
        var expiredObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(quote.plan)) as! [String: Any]
        expiredObject["createdAt"] = Date.now.addingTimeInterval(-91).timeIntervalSinceReferenceDate
        let expiredPlan = try JSONDecoder().decode(EVMSendPlan.self, from: JSONSerialization.data(withJSONObject: expiredObject))
        do {
            _ = try await service.submit(.init(walletID: quote.walletID, accountID: quote.accountID, assetID: quote.assetID, plan: expiredPlan),
                vault: vault, digits: pin, reason: "Test", walletConnectRequestID: id, authorization: {})
            preconditionFailure("Expired quote submitted")
        } catch { check(error is SendQuoteExpiredError, "A 91-second-old review is rejected before signing") }
        check(try await db.send(id) == nil, "Expired review leaves no reservation")
        let refreshed = try await service.walletConnectQuote(input, requestID: id, walletID: quote.walletID, accountID: quote.accountID, vault: vault)
        try refreshed.plan.validate()
        check(input.matches(refreshed.plan) && refreshed.plan.createdAt > expiredPlan.createdAt, "Same request can be refreshed for another explicit confirmation")
        check(await rpc.broadcasts == 0, "Refreshing a review never signs or broadcasts")
        let denied = AuthorizationGate(invalidAt: 1)
        do { _ = try await service.submit(quote, vault: vault, digits: pin, reason: "Test", walletConnectRequestID: id, authorization: { try await denied.validate() }); preconditionFailure("Stale request submitted") }
        catch { check(error is CancellationError, "Expired authorization is rejected before persistence") }
        check(try await db.send(id) == nil, "Denied request creates no draft")
        let expiredDuringAuthentication = AuthorizationGate(invalidAt: 2)
        do { _ = try await service.submit(quote, vault: vault, digits: pin, reason: "Test", walletConnectRequestID: id, authorization: { try await expiredDuringAuthentication.validate() }); preconditionFailure("Expired request submitted") }
        catch { check(error is CancellationError, "Authorization rechecked after authentication") }
        let cancelled = try await db.send(id)
        check(cancelled?.signedPayload == nil && cancelled?.state == "cancelled", "Expired request remains unsigned and retryable")
        check(await rpc.broadcasts == 0, "Expiry never broadcasts")
        let active = AuthorizationGate()
        do { _ = try await service.submit(quote, vault: vault, digits: [9,9,9,9,9,9], reason: "Test", walletConnectRequestID: id, authorization: { try await active.validate() }); preconditionFailure("Wrong PIN submitted") }
        catch { check(error as? OathWalletError == .wrongPasscode, "Wrong PIN rejected") }
        check(try await db.send(id)?.signedPayload == nil, "Failed PIN stores no signature")
        let result = try await service.submit(quote, vault: vault, digits: pin, reason: "Test", walletConnectRequestID: id, authorization: { try await active.validate() })
        check(result.accepted, "RPC acceptance returned")
        let stored = try await db.send(id)
        check(stored?.signedPayload != nil && stored?.state == "broadcast", "Exact signature journaled before acceptance")
        check(await rpc.broadcasts == 1, "Successful retry broadcasts exactly once")
        let repeatResult = try await service.submit(quote, vault: vault, digits: pin, reason: "Test", walletConnectRequestID: id, authorization: { try await active.validate() })
        check(repeatResult.txid == result.txid && repeatResult.accepted == result.accepted, "Replay preserves durable hash and observed network acceptance")
        check(await rpc.broadcasts == 1, "Replay does not broadcast or spend twice")
        var changed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(quote.plan)) as! [String: Any]
        changed["nonce"] = quote.plan.nonce + 1
        let otherPlan = try JSONDecoder().decode(EVMSendPlan.self, from: JSONSerialization.data(withJSONObject: changed))
        do { _ = try await service.submit(.init(walletID: quote.walletID, accountID: quote.accountID, assetID: quote.assetID, plan: otherPlan), vault: vault, digits: pin, reason: "Test", walletConnectRequestID: id, authorization: { try await active.validate() }); preconditionFailure("Replayed ID changed transaction") }
        catch { check(error as? EVMSendError == .changed, "Same request cannot change nonce or reviewed fees") }
        check(try await db.send(id)?.state == "broadcast", "Mismatch cannot cancel an existing broadcast")
        await rpc.advanceNonce()
        let restarted = OathEVMSendService(clients: [.ethereum: client])
        let recovered = try await restarted.walletConnectQuote(input, requestID: id, walletID: quote.walletID, accountID: quote.accountID, vault: vault)
        check(recovered == quote, "Restart recovers original nonce, fees and bytes")
        do { _ = try await restarted.walletConnectQuote(input, requestID: id, walletID: "other", accountID: quote.accountID, vault: vault); preconditionFailure("Cross-wallet replay accepted") }
        catch { check(error as? EVMSendError == .wrongOwner, "Cross-wallet replay rejected") }
        // Drive the real background worker -> EVM receipt validation -> SQL
        // observation -> app completion state -> shared haptic policy on host.
        var progress = OathWalletConnectTransactionProgress()
        var iterator = db.observeSendProgress(sendID: id).makeAsyncIterator()
        guard let pending = try await iterator.next() ?? nil else { preconditionFailure("Missing journal progress") }
        check(pending.outcome == .pending && pending.actualFee == nil, "Acceptance remains pending without a paid fee")
        check(!progress.update(pending), "Pending never emits success feedback")
        await rpc.confirm(plan: quote.plan, hash: result.txid)
        let worker = SendStatusTracker(database: db) { send in try await restarted.check(send: send, database: db) }
        await worker.resume()
        guard let confirmed = try await iterator.next() ?? nil else { preconditionFailure("Missing final progress") }
        await worker.pause()
        check(confirmed.outcome == .confirmed && confirmed.blockHeight == 100, "Background receipt reaches completion screen state")
        check(confirmed.actualFee == "21000000000000", "Actual receipt fee replaces the estimate atomically")
        let suite = "WalletConnectStatus-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var feedback: [OathHapticEvent] = []
        let haptics = OathHaptics(defaults: defaults, active: { true }, output: { feedback.append($0) })
        if progress.update(confirmed) { haptics.play(.success) }
        check(feedback == [.success], "Confirmation uses the shared success haptic")
        check(!progress.update(confirmed), "Duplicate receipt does not repeat success")
        var resumed = db.observeSendProgress(sendID: id).makeAsyncIterator()
        guard let initial = try await resumed.next() ?? nil else { preconditionFailure("Missing resumed progress") }
        check(!progress.update(initial), "Foreground resubscription does not repeat success")
        _ = progress.update(pending)
        check(!progress.update(confirmed), "Reconfirmation after reorg does not repeat the same transaction's feedback")
        var fast = OathWalletConnectTransactionProgress()
        check(fast.update(initial), "Already-confirmed first observation still emits success once")
        var muted = OathWalletConnectTransactionProgress()
        haptics.setEnabled(false)
        if muted.update(initial) { haptics.play(.success) }
        check(feedback == [.success], "User's disabled-haptics preference is respected")
        check(await rpc.broadcasts == 1, "Receipt tracking never signs or broadcasts a second transfer")
        // Approval included at latest but not finalized must not block the swap.
        let approvalID = "wc:" + String(repeating: "b", count: 64)
        let approvalBody = [["from": account.address, "to": "0x" + String(repeating: "3", count: 40), "value": "0x0",
            "data": "0x095ea7b3" + String(repeating: "0", count: 24) + String(repeating: "4", count: 40) + String(repeating: "f", count: 64)]]
        let approvalInput = try WalletConnectEVMRequest(params: JSONEncoder().encode(approvalBody), account: account.address, chainID: 1)
        let approvalQuote = try await restarted.walletConnectQuote(approvalInput, requestID: approvalID, walletID: quote.walletID, accountID: quote.accountID, vault: vault)
        let approval = try await restarted.submit(approvalQuote, vault: vault, digits: pin, reason: "Test", walletConnectRequestID: approvalID, authorization: {})
        await rpc.confirm(plan: approvalQuote.plan, hash: approval.txid, finalized: 99)
        try await restarted.check(send: db.send(approvalID)!, database: db)
        check(try await db.send(approvalID)?.state == "broadcast", "Unfinalized approval remains pending")

        let swapID = "wc:" + String(repeating: "c", count: 64)
        let swapBody = [["from": account.address, "to": "0x" + String(repeating: "4", count: 40), "value": "0x0", "data": "0x12345678"]]
        let swapInput = try WalletConnectEVMRequest(params: JSONEncoder().encode(swapBody), account: account.address, chainID: 1)
        do {
            let premature = try await restarted.walletConnectQuote(swapInput, requestID: swapID, walletID: quote.walletID, accountID: quote.accountID, vault: vault)
            _ = try await restarted.submit(premature, vault: vault, digits: pin, reason: "Test", walletConnectRequestID: swapID, authorization: {})
            preconditionFailure("Unknown contract effects cannot be skipped")
        } catch { check(error as? EVMSendError == .busy, "Dependent contract effects require provider pending state") }
        check(try await db.send(swapID) == nil, "Rejected quote never creates an unsigned reservation")
        await rpc.advanceNonce()
        let swapQuote = try await restarted.walletConnectQuote(swapInput, requestID: swapID, walletID: quote.walletID, accountID: quote.accountID, vault: vault)
        check(swapQuote.plan.nonce == approvalQuote.plan.nonce + 1, "Fresh quote uses the next mined nonce")
        let swap = try await restarted.submit(swapQuote, vault: vault, digits: pin, reason: "Test", walletConnectRequestID: swapID, authorization: {})
        check(swap.accepted, "Approval-to-swap flow proceeds before finality")
        check(try await db.send(approvalID)?.state == "broadcast", "Successor does not falsely confirm its predecessor")
        check(await rpc.broadcasts == 3, "Each authorized call broadcasts once")
        _ = try await restarted.submit(swapQuote, vault: vault, digits: pin, reason: "Test", walletConnectRequestID: swapID, authorization: {})
        check(await rpc.broadcasts == 3, "Follow-up replay cannot double-send")
        // Ordinary payments may proceed even before the RPC observes the prior
        // broadcast. Production service, vault and SQLite reservations run here.
        await rpc.advanceNonce()
        let token="0x"+String(repeating:"5",count:40)
        try await db.seed(networks:[],assets:[.init(id:"ethereum:"+token,networkID:"ethereum",reference:token,name:"Fixture USD",symbol:"USDT",decimals:6)])
        var paymentNonces=[UInt64]()
        for reference in [token,token,"native"] {
            let q=try await restarted.quote(network:.ethereum,walletID:quote.walletID,accountID:quote.accountID,assetID:"ethereum:"+reference,reference:reference,recipient:input.recipient,amount:"123",decimals:reference=="native" ? 18:6,maximum:false,vault:vault)
            paymentNonces.append(q.plan.nonce)
            if paymentNonces.count==2 { check(q.plan.assetBalance=="999877","Second token send reserves the first 123 atomic units") }
            let payment=try await restarted.submit(q,vault:vault,digits:pin,reason:"Test")
            check(payment.accepted,"New independent payment is broadcast while predecessor is pending")
        }
        let firstNonce=swapQuote.plan.nonce+1
        check(paymentNonces==[firstNonce,firstNonce+1,firstNonce+2],"Independent token and native payments receive distinct sequential nonces")
        check(await rpc.broadcasts==6,"Three independent payments each broadcast once")
        let commitments=try await db.evmSendReservations(network:.ethereum,sender:account.address)
        check(commitments.filter{$0.nonce>=firstNonce}.count==3,"All pending commitments remain durable")
        print("Passed \(checks) WalletConnect transaction authorization and durable-retry host checks. Production vault/submission/journal; deterministic RPC, no network or device.")
    }
}
