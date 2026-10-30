import Foundation

/// CCTP V1 pairs burns and mints by authenticated domain/nonce, never amounts.
/// V2 assigns its nonce offchain and requires separate attestation evidence.
enum EVMHistoryCCTP {
    struct Deployment {
        let domain: UInt64, testnet: Bool, messenger: String, transmitter: String
    }
    // Circle's published CCTP V1 EVM deployment registry.
    // developers.circle.com/cctp/v1/evm-smart-contracts
    static let deployments: [UInt64: Deployment] = {
        var rows: [UInt64: Deployment] = [:]
        func add(_ chain: UInt64, _ domain: UInt64, _ testnet: Bool, _ messenger: String, _ transmitter: String) {
            rows[chain] = .init(domain: domain, testnet: testnet, messenger: messenger.lowercased(), transmitter: transmitter.lowercased())
        }
        add(1, 0, false, "0xbd3fa81b58ba92a82136038b25adec7066af3155", "0x0a992d191deec32afe36203ad87d7d289a738f81")
        add(43114, 1, false, "0x6b25532e1060ce10cc3b0a99e5683b91bfde6982", "0x8186359af5f57fbb40c6b14a588d2a59c0c29880")
        add(10, 2, false, "0x2b4069517957735be00cee0fadae88a26365528f", "0x4d41f22c5a0e5c74090899e5a8fb597a8842b3e8")
        add(42161, 3, false, "0x19330d10d9cc8751218eaf51e8885d058642e08a", "0xc30362313fbba5cf9163f0bb16a0e01f01a896ca")
        add(8453, 6, false, "0x1682ae6375c4e4a97e4b583bc394c861a46d8962", "0xad09780d193884d503182ad4588450c416d6f9d4")
        add(137, 7, false, "0x9daf8c91aefae50b9c0e69629d3f6ca40ca3b3fe", "0xf3be9355363857f3e001be68856a2f96b4c39ba9")
        add(130, 10, false, "0x4e744b28e787c3ad0e810ed65a24461d4ac5a762", "0x353be9e2e38ab1d19104534e4edc21c643df86f4")
        for (chain, domain): (UInt64, UInt64) in [(11155111,0),(11155420,2),(84532,6),(80002,7)] {
            add(chain, domain, true, "0x9f3b8679c73c2fef8b59b4f3444d4e156fb70aa5", "0x7865fafc2db2093669d92c0f33aeef291086befd")
        }
        add(421614,3,true,"0x9f3b8679c73c2fef8b59b4f3444d4e156fb70aa5","0xacf1ceef35caac005e15888ddb8a3515c41b4872")
        add(43113,1,true,"0xeb08f243e5d3fcff26a9e38ae5520a669f4019d0","0xa9fb1b3009dcb79e2fe346c16a604b8fa8ae0a79")
        add(1301,10,true,"0x8ed94b8dad2dc5453862ea5e316a8e71aaed9782","0xbc498c326533d675cf571b90a2ced265acb7d086")
        return rows
    }()
    static func topic(_ text: String) -> String { "0x" + TronSendCrypto.hex(TronSendCrypto.keccak(Data(text.utf8))) }
    static let deposit = topic("DepositForBurn(uint64,address,uint256,address,bytes32,uint32,bytes32,bytes32)")
    static let received = topic("MessageReceived(address,uint32,uint64,bytes32,bytes)")
    static let minted = topic("MintAndWithdraw(address,uint256,address)")

    static func proof(logs: [SolanaJSON], owner: String, chainID: UInt64) throws -> EVMHistoryBridge? {
        guard let local = deployments[chainID] else { return nil }
        func remote(_ domain: UInt64) -> Deployment? {
            deployments.values.first { $0.domain == domain && $0.testnet == local.testnet && domain != local.domain }
        }
        func key(_ origin: UInt64, _ destination: UInt64, _ nonce: String) -> String {
            "cctp1:\(local.testnet ? "test" : "main"):\(origin):\(destination):\(nonce)"
        }
        func abi(_ log: SolanaJSON) -> WalletConnectCallDetails.ABI? {
            guard let raw = log["data"].string, let bytes = try? TronIdentity.hex(raw) else { return nil }
            return .init(Array(bytes))
        }
        func topicAddress(_ text: String?) -> String? {
            guard let text, let data = try? TronIdentity.hex(text), data.count == 32 else { return nil }
            return WalletConnectCallDetails.ABI(Array(data)).address(0)
        }
        let deposits = logs.filter { $0["address"].string?.lowercased() == local.messenger && $0["topics"].array?.first?.string == deposit }
        let messages = logs.filter { $0["address"].string?.lowercased() == local.transmitter && $0["topics"].array?.first?.string == received }
        if deposits.count == 1, messages.isEmpty, let log = deposits.first,
           let topics = log["topics"].array, topics.count == 4, topicAddress(topics[3].string) == owner,
           let token = topicAddress(topics[2].string), let nonceHex = topics[1].string,
           let nonce = UInt64(try AnkrQuantity.decimal(nonceHex)), let a = abi(log), a.bytes.count == 160,
           let amount = a.uint(0), a.address(1) == owner, let domainText = a.uint(2), let domain = UInt64(domainText),
           let destination = remote(domain), a.address(3) == destination.messenger {
            return .init(key: key(local.domain, domain, String(nonce)), direction: "outgoing", asset: token, amount: amount, protocolName: "CCTP")
        }
        let mints = logs.filter { $0["address"].string?.lowercased() == local.messenger && $0["topics"].array?.first?.string == minted }
        guard deposits.isEmpty, messages.count == 1, mints.count == 1,
              let log = messages.first, let topics = log["topics"].array, topics.count == 3,
              let nonceHex = topics[2].string, let nonce = UInt64(try AnkrQuantity.decimal(nonceHex)),
              let a = abi(log), let domainText = a.uint(0), let domain = UInt64(domainText), let source = remote(domain),
              a.address(1) == source.messenger, a.integer(2) == 96,
              let body = a.blob(96), body.end == a.bytes.count, body.value.count == 132,
              body.value.prefix(4).allSatisfy({ $0 == 0 }) else { return nil }
        let burn = WalletConnectCallDetails.ABI(Array(body.value.dropFirst(4)))
        guard burn.address(1) == owner, burn.address(3) == owner, let amount = burn.uint(2),
              let mint = mints.first, let mt = mint["topics"].array, mt.count == 3,
              topicAddress(mt[1].string) == owner, let token = topicAddress(mt[2].string),
              let ma = abi(mint), ma.bytes.count == 32, ma.uint(0) == amount else { return nil }
        return .init(key: key(domain, local.domain, String(nonce)), direction: "incoming", asset: token, amount: amount, protocolName: "CCTP")
    }
}
