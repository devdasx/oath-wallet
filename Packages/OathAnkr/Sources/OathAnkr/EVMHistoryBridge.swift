import Foundation

/// Proven receipt leg, not an inferred match by time, amount or symbol. Quotes
/// are used only to authenticate Across relay identity, never as received funds.
public struct EVMHistoryBridge: Codable, Sendable, Equatable {
    public let key: String
    public let direction: String
    public let asset: String
    public let amount: String
    public let protocolName: String

    public static func classify(_ evidence: EVMHistoryEvidence, owner: String, chainID: UInt64) throws -> Self? {
        let owner = try EVMSendIdentity.address(owner)
        let tx = evidence.transaction, receipt = evidence.receipt
        guard let hash = tx["hash"].string?.lowercased(), hash.count == 66,
              receipt["transactionHash"].string?.lowercased() == hash,
              let block = tx["blockHash"].string?.lowercased(), block.count == 66,
              receipt["blockHash"].string?.lowercased() == block, receipt["status"].string == "0x1",
              let sender = tx["from"].string?.lowercased(), receipt["from"].string?.lowercased() == sender,
              let to = tx["to"].string?.lowercased(), receipt["to"].string?.lowercased() == to,
              let logs = receipt["logs"].array, logs.count <= 2048 else { return nil }
        if let chain = tx["chainId"].string, try AnkrQuantity.decimal(chain) != String(chainID) { return nil }
        let native = try evidence.trace?.movements(transaction: tx, receipt: receipt, owner: owner, chainID: chainID)
        var seen: [String: SolanaJSON] = [:], credits: [String: String] = [:], debits: [String: String] = [:]
        var proofs: [(String, String, String, String?, String?)] = []
        var successfulOwnerOperations = 0
        var nativeDeposit: (asset: String, amount: String)?
        for log in logs {
            guard log["removed"] != .bool(true), log["transactionHash"].string?.lowercased() == hash,
                  log["blockHash"].string?.lowercased() == block, let rawIndex = log["logIndex"].string,
                  let emitter = log["address"].string?.lowercased(),
                  let topics = log["topics"].array?.compactMap(\.string).map({ $0.lowercased() }), !topics.isEmpty,
                  let data = log["data"].string, let bytes = try? TronIdentity.hex(data), bytes.count % 32 == 0 else { return nil }
            let index = try AnkrQuantity.decimal(rawIndex)
            if let old = seen[index] { guard old == log else { return nil }; continue }
            seen[index] = log
            let words = stride(from: 0, to: bytes.count, by: 32).map { "0x" + TronSendCrypto.hex(Data(bytes[$0..<$0+32])) }
            if entryPoints.contains(emitter), to == emitter,
               topics.count == 4, topics[0] == userOperation, address(topics[2]) == owner,
               words.count == 4, try AnkrQuantity.decimal(words[1]) == "1" {
                successfulOwnerOperations += 1
            }
            if topics[0] == EVMHistorySwap.transferTopic {
                guard topics.count == 3, words.count == 1, let from = address(topics[1]), let recipient = address(topics[2]) else { return nil }
                let amount = try EVMSendAmount.checked(AnkrQuantity.decimal(words[0]))
                if emitter == "0xfffffffffffffffffffffffffffffffffffffffe",
                   native?.transfers.contains(where: { $0.from == from && $0.to == recipient && $0.amount == amount }) == true { continue }
                let ref = try EVMHistorySwap.reference(emitter, chainID: chainID)
                if from == owner { debits[ref] = try EVMSendAmount.add(debits[ref] ?? "0", amount) }
                if recipient == owner { credits[ref] = try EVMSendAmount.add(credits[ref] ?? "0", amount) }
            }
            if emitter == spokes[chainID], topics.count == 4 {
                if topics[0] == deposited, words.count >= 11, address(topics[3]) == owner,
                   address(words[7]) == owner, let destination = UInt64(try AnkrQuantity.decimal(topics[1])),
                   destination != chainID, spokes[destination] != nil,
                   try AnkrQuantity.decimal(words[9]) == "320", try AnkrQuantity.decimal(words[10]) == "0", words.count == 11 {
                    let key = acrossKey(origin: chainID, destination: destination, deposit: topics[2],
                        fields: Array(words[0...3]) + [words[5], words[6], words[8], topics[3], words[7]])
                    proofs.append((key, "outgoing", "Across", nil, nil))
                    if let asset = address(words[0]) { nativeDeposit = (asset, try AnkrQuantity.decimal(words[2])) }
                } else if topics[0] == filled, words.count == 15,
                          address(words[8]) == owner, address(words[9]) == owner, address(words[11]) == owner,
                          words[10] == zero, words[12] == zero, words[13] == words[3],
                          try AnkrQuantity.decimal(words[14]) == "0",
                          let origin = UInt64(try AnkrQuantity.decimal(topics[1])), origin != chainID, spokes[origin] != nil,
                          let token = address(words[1]) {
                    let key = acrossKey(origin: origin, destination: chainID, deposit: topics[2],
                        fields: Array(words[0...3]) + [words[5], words[6], words[7], words[8], words[9]])
                    proofs.append((key, "incoming", "Across", try EVMHistorySwap.reference(token, chainID: chainID), try AnkrQuantity.decimal(words[13])))
                }
            }
            if emitter == "0x4cd00e387622c35bddb9b4c962c136462338bc31", topics == [relayDeposit],
               words.count == 4, address(words[0]) == owner, words[3] != zero {
                proofs.append(("relay:" + words[3], "outgoing", "Relay", nil, nil))
                if let asset = address(words[1]) { nativeDeposit = (asset, try AnkrQuantity.decimal(words[2])) }
            }
            // Only the final router's payment to this owner proves delivery;
            // the approval proxy and intermediate pool events are not receipts.
            if relayRouters.contains(emitter), topics == [relayExecution], words.count == 8,
               address(words[0]) == emitter, address(words[1]) == owner, let token = address(words[2]),
               try AnkrQuantity.decimal(words[4]) == "160", try AnkrQuantity.decimal(words[5]) == "33",
               words[6] != zero, words[7] == zero {
                let requestID: String
                if to == relayPermit2Proxy {
                    guard let outerID = relayPermit2RequestID(tx, owner: owner, metadata: words[6]) else { return nil }
                    requestID = outerID
                } else {
                    requestID = words[6]
                }
                proofs.append(("relay:" + requestID, "incoming", "Relay", try EVMHistorySwap.reference(token, chainID: chainID), try AnkrQuantity.decimal(words[3])))
            }
        }
        if let cctp = try EVMHistoryCCTP.proof(logs: Array(seen.values), owner: owner, chainID: chainID) {
            proofs.append((cctp.key, cctp.direction, cctp.protocolName, cctp.asset, cctp.amount))
        }
        guard proofs.count == 1, let proof = proofs.first else { return nil }
        // Bundlers submit the source transaction for the owner. Require the
        // EntryPoint's successful owner operation, not just an arbitrary relayer.
        if proof.1 == "outgoing", sender != owner, successfulOwnerOperations != 1 { return nil }
        if sender == owner, let value = tx["value"].string, try AnkrQuantity.decimal(value) != "0", native == nil { return nil }
        if chainID == 42220, credits["native"] != nil || debits["native"] != nil { return nil }
        if let native { credits["native"] = native.credits; debits["native"] = native.debits }
        var outgoing: [(String,String)] = [], incoming: [(String,String)] = []
        for ref in Set(credits.keys).union(debits.keys) {
            let credit = credits[ref] ?? "0", debit = debits[ref] ?? "0"
            if EVMSendAmount.less(credit, debit) { outgoing.append((ref, try EVMSendAmount.subtract(debit, credit))) }
            if EVMSendAmount.less(debit, credit) { incoming.append((ref, try EVMSendAmount.subtract(credit, debit))) }
        }
        let legs = proof.1 == "outgoing" ? outgoing : incoming
        guard legs.count == 1, (proof.1 == "outgoing" ? incoming : outgoing).isEmpty else { return nil }
        let leg = legs[0]
        if proof.1 == "outgoing", leg.0 == "native" {
            // A native fee accompanying somebody else's token bridge is not a
            // native deposit. Require the protocol's exact native/wrapped leg.
            guard let deposit = nativeDeposit, deposit.amount == leg.1,
                  deposit.asset == "0x" + String(repeating: "0", count: 40)
                    || deposit.asset == EVMHistoryTrace.wrappedNative[chainID] else { return nil }
        }
        if let asset = proof.3, asset != leg.0 {
            guard native != nil, leg.0 == "native",
                  asset == EVMHistoryTrace.wrappedNative[chainID] || asset == "0x" + String(repeating: "0", count: 40) else { return nil }
        }
        if let amount = proof.4, amount != leg.1 { return nil }
        return .init(key: proof.0, direction: proof.1, asset: leg.0, amount: leg.1, protocolName: proof.2)
    }

    // Relay v3.2 Permit2 fills append the original bridge request ID after
    // the ABI payload. FundsMovement.metadata identifies the nested execution,
    // which can differ from the deposit ID. Accept only the registered proxy,
    // canonical bounded ABI and matching final-payment metadata/recipient.
    // This is history attribution only; receipt transfers remain the amount source.
    private static let relayPermit2Proxy = "0x5567954cd026cebfe486062cb75848e0f1c12e58"
    private static func relayPermit2RequestID(_ tx: SolanaJSON, owner: String, metadata: String) -> String? {
        guard let input = tx["input"].string, input.count <= 262_146,
              let data = try? TronIdentity.hex(input), data.count >= 4,
              TronSendCrypto.hex(Data(data.prefix(4))) == "0a2b8f36" else { return nil }
        let abi = WalletConnectCallDetails.ABI(Array(data.dropFirst(4)))
        guard abi.address(0) != nil, abi.integer(1) == 224,
              abi.address(3) == owner, abi.address(4) == owner,
              abi.integer(7) == 96, let tokenCount = abi.integer(10), (1...64).contains(tokenCount),
              let callsOffset = abi.integer(2), callsOffset == 352 + tokenCount * 64,
              let callsCount = abi.integer(callsOffset / 32), (1...64).contains(callsCount) else { return nil }
        for i in 0..<tokenCount {
            guard abi.address(11 + i * 2) != nil else { return nil }
        }
        let base = callsOffset + 32
        var cursor = base + callsCount * 32
        for i in 0..<callsCount {
            guard abi.integer(base / 32 + i) == cursor - base,
                  abi.address(cursor / 32) != nil,
                  let allowFailure = abi.integer(cursor / 32 + 1), (0...1).contains(allowFailure),
                  abi.integer(cursor / 32 + 3) == 128,
                  let call = abi.blob(cursor + 128) else { return nil }
            cursor = call.end
        }
        guard abi.integer(5) == cursor, let payload = abi.blob(cursor), payload.value.count == 33,
              payload.value.last == 0,
              "0x" + TronSendCrypto.hex(Data(payload.value.prefix(32))) == metadata,
              abi.integer(6) == payload.end, let signature = abi.blob(payload.end),
              [64,65].contains(signature.value.count), signature.end + 32 == abi.bytes.count else { return nil }
        let requestID = "0x" + TronSendCrypto.hex(Data(abi.bytes.suffix(32)))
        return requestID == zero ? nil : requestID
    }

    private static let entryPoints: Set<String> = [
        "0x5ff137d4b0fdcd49dca30c7cf57e578a026d2789", // ERC-4337 v0.6
        "0x0000000071727de22e5e9d8baf0edac6f37da032", // v0.7
        "0x4337084d9e255ff0702461cf8895ce9e3b5ff108"  // v0.8
    ]
    private static let userOperation = "0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f"
    private static let zero = "0x" + String(repeating: "0", count: 64)
    private static func address(_ word: String) -> String? {
        guard word.count == 66, word.hasPrefix("0x" + String(repeating: "0", count: 24)) else { return nil }
        return try? EVMSendIdentity.address("0x" + word.suffix(40))
    }
    private static func acrossKey(origin: UInt64, destination: UInt64, deposit: String, fields: [String]) -> String {
        "across:\(origin):\(destination):" + TronSendCrypto.hex(TronSendCrypto.keccak(Data(([deposit] + fields).joined().utf8)))
    }
    static let deposited = "0x32ed1a409ef04c7b0227189c3a103dc5ac10e775a15b785dcc510201f7c25ad3"
    static let filled = "0x44b559f101f8fbcc8a0ea43fa91a05a729a5ea6e14a7c75aa750374690137208"
    static let relayDeposit = "0x49fed1d0b752ce30eee63c7a81133f3363b532fec5d4d7dd1ccfd005de4555e1"
    static let relayExecution = "0xafbab204e8271965231d37baed9b1abca8725b7409c70314455f68bc89142b91"
    // Official deployment registries, pinned 2026-10-27:
    // github.com/across-protocol/contracts/broadcast/deployed-addresses.json
    // docs.relay.link/references/api/api_resources/contract-addresses
    static let relayRouters: Set<String> = [
        "0x113a327221d2c4660684449bfc39bc14ad1aaf38", "0xf5042e6ffac5a625d4e7848e0b01373d8eb9e222",
        "0x8fdceeda2951a9747feaf25311435448bce47b2a", "0xb758f3bfa7b9d39ef5457d7c7ffb3702f2ad3982",
        "0x3ec130b627944cad9b2750300ecb0a695da522b6", "0x9ef6d3c2f60d7b9008d74cab1fc0f899c957c819",
        "0xb92fe925dc43a0ecde6c8b1a2709c170ec4fff4f", "0xe16870b028704e38dbc254a84d3f72c8ba345ca9",
        "0x6328ea02d28131e58b28e55c6258258a30d90e05", "0x0729e2a4716d9f7dd17858d5d504426d228697f7"
    ]
    static let spokes: [UInt64:String] = [
        1:"0x5c7bcd6e7de5423a257d81b442095a1a6ced35c5",
        10:"0x6f26bf09b1c792e3228e5467807a900a503c0281",
        56:"0x4e8e101924ede233c13e2d8622dc8aed2872d505",
        130:"0x09aea4b2242abc8bb4bb78d537a67a245a7bec64",
        137:"0x9295ee1d8c5b022be115a2ad3c30c72e34e7f096",
        143:"0xd2ecb3afe598b746f8123cae365a598da831a449",
        999:"0x35e63ea3eb0fb7a3bc543c71fb66412e1f6b0e04",
        4663:"0xd29c85f15df544ba632c9e25829fd29d767d7978",
        5042:"0x9b4a302a548c7e313c2b74c461db7b84d3074a84",
        8453:"0x09aea4b2242abc8bb4bb78d537a67a245a7bec64",
        42161:"0xe35e9842fceaca96570b734083f4a58e8f7c5f2a",
        43114:"0xfe9d541c92e4e90437c7152a00244886de37a658",
        59144:"0x7e63a5f1a8f0b4d0934b2f2327daed3f6bb2ee75",
    ]
}
