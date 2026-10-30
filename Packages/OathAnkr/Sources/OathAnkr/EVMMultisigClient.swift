import Foundation
import OathDiagnostics

public struct EVMMultisigState: Sendable {
    public let configured: Bool
    public let nonce: UInt64
    public let executorBalance: String
}
extension EVMSendClient {
    private static func emptyStorage(_ value: SolanaJSON) -> Bool {
        // Some clients encode an untouched slot as empty DATA rather than 32 zero bytes.
        value.string == "0x" || value.string == "0x" + String(repeating: "0", count: 64)
    }
    public func multisigState(_ policy: EVMMultisigPolicy) async throws -> EVMMultisigState {
        try policy.validate()
        let address = try policy.address
        async let factory = rpc("eth_getCode", [.string(EVMMultisigPolicy.factory), .string("latest")])
        async let singleton = rpc("eth_getCode", [.string(EVMMultisigPolicy.singleton), .string("latest")])
        async let proxy = rpc("eth_getCode", [.string(address), .string("latest")])
        async let funds = balance(owner: policy.executor, reference: "native")
        let (f, s, p, b) = try await (factory, singleton, proxy, funds)
        guard let fh = f.string, let sh = s.string, let ph = p.string,
              try TronSendCrypto.hex(TronSendCrypto.keccak(TronIdentity.hex(fh))) == EVMMultisigPolicy.factoryHash,
              try TronSendCrypto.hex(TronSendCrypto.keccak(TronIdentity.hex(sh))) == EVMMultisigPolicy.singletonHash else { throw EVMSendError.configuration }
        if ph == "0x" { return .init(configured: false, nonce: 0, executorBalance: b) }
        guard ph.lowercased() == "0x" + EVMMultisigPolicy.proxyRuntime else { throw EVMSendError.changed }
        async let master = rpc("eth_getStorageAt", [.string(address), .string("0x0"), .string("latest")])
        async let owners = call(address, "0x" + TronSendCrypto.hex(SafeABI.selector("getOwners()")), .string("latest"))
        async let threshold = call(address, "0x" + TronSendCrypto.hex(SafeABI.selector("getThreshold()")), .string("latest"))
        async let nonce = call(address, "0x" + TronSendCrypto.hex(SafeABI.selector("nonce()")), .string("latest"))
        // Reject modules, guards and fallback handlers, even if owner/threshold
        // still match. They could otherwise bypass the reviewed signer policy.
        async let modules = call(address, "0x" + TronSendCrypto.hex(try SafeABI.selector("getModulesPaginated(address,uint256)") + SafeABI.address("0x0000000000000000000000000000000000000001") + SafeABI.uint(1)), .string("latest"))
        async let guardSlot = rpc("eth_getStorageAt", [.string(address), .string("0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8"), .string("latest")])
        async let fallback = rpc("eth_getStorageAt", [.string(address), .string("0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5"), .string("latest")])
        let (masterValue, ownerValue, t, n, moduleValue, g, h) = try await (master, owners, threshold, nonce, modules, guardSlot, fallback)
        let expectedOwners = try SafeABI.uint(32) + SafeABI.uint(policy.owners.count) + policy.owners.map(SafeABI.address).reduce(Data(), +)
        let emptyModules = try SafeABI.uint(64) + SafeABI.uint(1) + SafeABI.uint(0)
        guard masterValue.string?.lowercased() == "0x" + (try TronSendCrypto.hex(SafeABI.address(EVMMultisigPolicy.singleton))),
              ownerValue.string?.lowercased() == "0x" + TronSendCrypto.hex(expectedOwners),
              try Self.uint(t) == policy.required, Self.emptyStorage(g), Self.emptyStorage(h),
              moduleValue.string?.lowercased() == "0x" + TronSendCrypto.hex(emptyModules) else { throw EVMSendError.changed }
        return try .init(configured: true, nonce: Self.uint(n), executorBalance: b)
    }
    public func quoteMultisig(policy: EVMMultisigPolicy, recipient: String, reference: String, decimals: Int,
                              amount: String, maximum: Bool = false, setup: Bool = false) async throws -> EVMSendPlan {
        let sender = try policy.address, to = try network.address(recipient), ref = try EVMSendIdentity.reference(reference)
        guard sender != to else { throw EVMSendError.sameRecipient }
        let state = try await multisigState(policy)
        if !setup, !state.configured { throw EVMSendError.multisigSetupRequired }
        guard state.configured != setup else { throw EVMSendError.changed }
        guard !setup || (to == EVMMultisigPolicy.factory && ref == "native" && amount == "0") else { throw EVMSendError.changed }
        let head = try await block(.string("latest")), height = try Self.uint(head["number"])
        guard abs(Double(try Self.uint(head["timestamp"])) - Date.now.timeIntervalSince1970) < 60 else { throw EVMSendError.expired }
        async let funds = balance(owner: sender, reference: "native")
        async let token = balance(owner: sender, reference: ref)
        async let count = rpc("eth_getTransactionCount", [.string(policy.executor), .string(network.nonceTag)])
        async let price = rpc("eth_gasPrice", [])
        async let precision = self.decimals(ref, tag: .string("latest"))
        let (native, asset, nonce, gasPrice, d) = try await (funds, token, count, price, precision)
        guard d == decimals else { throw EVMSendError.metadataChanged }
        let legacy = head["baseFeePerGas"].isNull, base = legacy ? 0 : try Self.uint(head["baseFeePerGas"]), market = try Self.uint(gasPrice)
        guard base <= 100_000_000_000_000, market > 0, market <= 100_000_000_000_000 else { throw EVMSendError.feeTooHigh }
        var tip = legacy ? 0 : (market > base ? market - base : 0), ceiling = max(market, base * 2 + tip)
        let value = maximum ? asset : try EVMSendAmount.checked(amount)
        let context = EVMMultisigContext(policy: policy, safeNonce: state.nonce, executorBalance: state.executorBalance, setup: setup)
        func make(_ gas: UInt64, extra: UInt64 = 0) throws -> EVMSendPlan {
            .init(network: network, sender: sender, recipient: to, reference: ref, decimals: decimals,
                  requestedAmount: value, amount: value, assetBalance: asset, nativeBalance: native,
                  nonce: try Self.uint(nonce), gasLimit: gas, maxFeePerGas: ceiling, maxPriorityFeePerGas: tip,
                  blockHeight: height, legacy: legacy, extraFee: extra, multisig: context)
        }
        let probe = try make(network.maximumGas)
        let payload: SolanaJSON
        if setup {
            payload = .object(["from": .string(policy.executor), "to": .string(EVMMultisigPolicy.factory), "data": .string("0x" + TronSendCrypto.hex(try policy.deploymentData()))])
        } else {
            payload = .object(["from": .string(sender), "to": .string(probe.receiver), "value": .string(try EVMSendAmount.hex(probe.value)), "data": .string("0x" + TronSendCrypto.hex(try EVMSendCrypto.data(probe)))])
        }
        let innerEstimate: UInt64
        if network == .linea {
            let line = try await rpc("linea_estimateGas", [payload])
            innerEstimate = try Self.uint(line["gasLimit"])
            let b = try Self.uint(line["baseFeePerGas"]), p = try Self.uint(line["priorityFeePerGas"])
            guard b <= 100_000_000_000_000, p <= 100_000_000_000_000 else { throw EVMSendError.feeTooHigh }
            tip = legacy ? 0 : p; ceiling = max(ceiling, b * 2 + p)
        } else { innerEstimate = try await Self.uint(rpc("eth_estimateGas", [payload])) }
        // Conservative bound before authorization; exact signed outer calldata
        // must pass estimate + eth_call before it can enter the durable journal.
        guard innerEstimate <= network.maximumGas else { throw EVMSendError.feeTooHigh }
        let gas = setup ? innerEstimate + innerEstimate / 5 + 10_000 : innerEstimate * 2 + 150_000 + UInt64(policy.required) * 30_000
        guard gas <= network.maximumGas else { throw EVMSendError.feeTooHigh }
        let preliminary = try make(gas)
        let dummy = Data(repeating: 255, count: setup ? 0 : policy.required * 65)
        let extra = try await extraFee(EVMMultisigCrypto.outer(preliminary, signatures: dummy))
        let plan = try make(gas, extra: extra)
        try plan.validate()
        try await preflightMultisig(plan)
        return plan
    }
    func preflightMultisig(_ plan: EVMSendPlan) async throws {
        try plan.validate(); guard plan.network == network, let m = plan.multisig else { throw EVMSendError.changed }
        let state = try await multisigState(m.policy)
        guard state.configured != m.setup, state.nonce == m.safeNonce else { throw EVMSendError.changed }
        guard !EVMSendAmount.less(state.executorBalance, String(plan.fee)) else { throw EVMSendError.multisigFunding }
        async let nonce = rpc("eth_getTransactionCount", [.string(m.policy.executor), .string(network.nonceTag)])
        async let funds = balance(owner: plan.sender, reference: plan.reference)
        async let d = decimals(plan.reference, tag: .string("latest"))
        let (n, b, precision) = try await (nonce, funds, d)
        guard try Self.uint(n) == plan.nonce, !EVMSendAmount.less(b, plan.amount), precision == plan.decimals else { throw EVMSendError.changed }
        if !m.setup {
            let payload: SolanaJSON = .object(["from": .string(plan.sender), "to": .string(plan.receiver), "value": .string(try EVMSendAmount.hex(plan.value)), "data": .string("0x" + TronSendCrypto.hex(try EVMSendCrypto.data(plan)))])
            let result = try await rpc("eth_call", [payload, .string("latest")])
            guard let output = result.string else { throw EVMSendError.malformed }
            if plan.reference != "native", output != "0x" {
                guard output.count == 66, try Self.quantity(result) == "1" else { throw EVMSendError.simulationFailed }
            }
        }
    }
    public func validateSignedMultisig(_ signed: EVMSignedSend, plan: EVMSendPlan) async throws {
        guard plan.multisig != nil else { return }
        try EVMMultisigCrypto.verify(signed, plan: plan)
        try await preflightMultisig(plan)
        let outer = try EVMMultisigCrypto.outer(plan, signatures: signed.multisigSignatures!)
        try await preflight(outer)
    }
    func submitMultisig(_ signed: EVMSignedSend, plan: EVMSendPlan, reconcileFirst: Bool) async throws -> EVMSendReceipt {
        try EVMMultisigCrypto.verify(signed, plan: plan)
        if reconcileFirst {
            let current = try await statusMultisig(signed, plan: plan)
            if current.outcome != .unknown { return current }
        } else { try plan.validate() }
        let outer = try EVMMultisigCrypto.outer(plan, signatures: signed.multisigSignatures!)
        let result = try await submit(.init(bytes: signed.bytes, signature: signed.signature, hash: signed.hash), plan: outer, reconcileFirst: reconcileFirst)
        // A receipt may appear between the two recovery reads. Always interpret
        // a confirmed outer transaction using the Safe's inner execution logs.
        if result.outcome == .confirmed || result.inclusion != nil { return try await statusMultisig(signed, plan: plan) }
        return result
    }
    func statusMultisig(_ signed: EVMSignedSend, plan: EVMSendPlan) async throws -> EVMSendReceipt {
        try EVMMultisigCrypto.verify(signed, plan: plan)
        let outer = try EVMMultisigCrypto.outer(plan, signatures: signed.multisigSignatures!)
        let result = try await status(.init(bytes: signed.bytes, signature: signed.signature, hash: signed.hash), plan: outer)
        guard result.outcome == .confirmed || result.inclusion?.succeeded == true,
              let m = plan.multisig else { return result }
        let receipt = try await rpc("eth_getTransactionReceipt", [.string(signed.hash)])
        guard receipt["transactionHash"].string?.lowercased() == signed.hash,
              try Self.uint(receipt["blockNumber"]) == (result.inclusion?.height ?? result.height),
              try Self.uint(receipt["status"]) == 1,
              let blockHash = receipt["blockHash"].string, AnkrQuantity.hash(blockHash),
              result.inclusion.map({ $0.blockHash == blockHash }) ?? true,
              try await block(receipt["blockNumber"])["hash"].string == blockHash,
              let logs = receipt["logs"].array, logs.count <= 10_000 else { throw EVMSendError.changed }
        if m.setup {
            let addressTopic = try "0x" + TronSendCrypto.hex(SafeABI.address(plan.sender))
            guard logs.contains(where: { $0["address"].string?.lowercased() == EVMMultisigPolicy.factory && $0["topics"].array?.first?.string?.lowercased() == "0x" + TronSendCrypto.hex(TronSendCrypto.keccak(Data("ProxyCreation(address,address)".utf8))) && $0["topics"].array?.dropFirst().first?.string?.lowercased() == addressTopic }) else { throw EVMSendError.changed }
            return result
        }
        let hash = try EVMMultisigCrypto.digest(plan)
        let success = logs.contains { log in
            log["address"].string?.lowercased() == plan.sender && log["topics"].array?.first?.string?.lowercased() == "0x" + TronSendCrypto.hex(TronSendCrypto.keccak(Data("ExecutionSuccess(bytes32,uint256)".utf8))) && log["topics"].array?.count == 2 && log["topics"].array?[1].string?.lowercased() == "0x" + TronSendCrypto.hex(hash) && log["data"].string == "0x" + String(repeating: "0", count: 64)
        }
        guard success else { throw EVMSendError.execution }
        var delivered: String?
        if plan.reference != "native" {
            let from = try "0x" + TronSendCrypto.hex(SafeABI.address(plan.sender)), to = try "0x" + TronSendCrypto.hex(SafeABI.address(plan.recipient))
            var total = "0"
            for log in logs where log["address"].string?.lowercased() == plan.reference {
                if log["topics"].array?.map({ $0.string?.lowercased() }) == [EVMSendIdentity.transferTopic, from, to] { total = try EVMSendAmount.add(total, Self.quantity(log["data"])) }
            }
            delivered = total
            if total != plan.amount {
                OathDiagnostics.record(EVMSendError.execution, component: "evm_send", operation: "verify_token_delivery", context: ["chain": network.rawValue, "stage": "receipt"])
            }
        }
        if let inclusion = result.inclusion {
            return .init(hash: result.hash, outcome: .accepted, inclusion: .init(succeeded: true,
                blockHash: inclusion.blockHash, fee: inclusion.fee, height: inclusion.height,
                timestamp: inclusion.timestamp, deliveredAmount: delivered))
        }
        return .init(hash: result.hash, outcome: .confirmed, fee: result.fee, height: result.height, timestamp: result.timestamp, deliveredAmount: delivered)
    }
}
