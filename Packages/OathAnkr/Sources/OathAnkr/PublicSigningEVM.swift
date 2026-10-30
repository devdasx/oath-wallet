import CryptoKit
import Foundation

extension PublicSigningAuthority {
    // Public mainnet endpoints only. eth_chainId is checked before every scan.
    static let evmEndpoints: [String: String] = [
        "ethereum": "https://ethereum-rpc.publicnode.com", "bnb": "https://bsc-dataseed.bnbchain.org",
        "arbitrum": "https://arbitrum-one-rpc.publicnode.com", "avalanche": "https://avalanche-c-chain-rpc.publicnode.com",
        "base": "https://mainnet.base.org", "optimism": "https://mainnet.optimism.io",
        "polygon": "https://polygon-bor-rpc.publicnode.com", "gnosis": "https://rpc.gnosischain.com",
        "linea": "https://rpc.linea.build", "scroll": "https://rpc.scroll.io",
        "taiko": "https://rpc.mainnet.taiko.xyz", "telos": "https://rpc.telos.net",
        "xlayer": "https://rpc.xlayer.tech", "arc": "https://arc-rpc.publicnode.com",
        "fantom": "https://rpcapi.fantom.network", "flare": "https://flare-api.flare.network/ext/C/rpc",
        "somnia": "https://api.infra.mainnet.somnia.network", "story": "https://mainnet.storyrpc.io",
        "monad": "https://rpc.monad.xyz", "unichain": "https://mainnet.unichain.org", "chiliz": "https://chiliz-rpc.publicnode.com", "celo": "https://forno.celo.org",
        "hyperevm": "https://rpc.hyperliquid.xyz/evm", "robinhood": "https://rpc.mainnet.chain.robinhood.com"
    ]

    // Official Safe 1.3.0 / 1.4.1 artifacts. Match the proxy AND implementation
    // bytecode; arbitrary contracts exposing getOwners/getThreshold are not proof.
    static let safeProxySHA256: Set<String> = [
        "5b8bff324e02136edb0775bd77aa0fe773c1e23092305fe63f50a9e92f5b8faf",
        "a8a0fbd3cdf49e751346664e01b529a58322a814cf8df8d85deb20e63bd6415e"
    ]
    static let safeImplementationKeccak: Set<String> = [
        "bba688fbdb21ad2bb58bc320638b43d94e7d100f6f3ebaab0a4e4de6304b1c2e",
        "21842597390c4c6e3c1239e434a682b054bd9548eee5e9b1d6a4482731023c0f",
        "1fe2df852ba3299d6534ef416eefa406e56ced995bca886ab7a553e6d0c5e1c4",
        "b1f926978a0f44a2c0ec8fe822418ae969bd8c3f18d61e5103100339894f81ff"
    ]

    func evm(_ account: PublicSigningAccount, endpoint: String) async throws -> PublicSigningAssessment {
        let address = try EVMSendIdentity.address(account.address)
        let chain = account.network == "arc" ? UInt64(5042) : EVMSendNetwork(rawValue: account.network)?.chainID
        guard let chain else { throw Failure.wrongNetwork }
        let actual = try await rpc(endpoint, "eth_chainId", .array([]))
        guard let hex = actual.string, hex.hasPrefix("0x"), UInt64(hex.dropFirst(2), radix: 16) == chain else {
            throw Failure.wrongNetwork
        }
        let block = try await rpc(endpoint, "eth_blockNumber", .array([]))
        guard let tag = block.string, tag.hasPrefix("0x"), UInt64(tag.dropFirst(2), radix: 16) != nil else { throw Failure.malformed }
        let code = try await rpc(endpoint, "eth_getCode", .array([.string(address), block]))
        guard let raw = code.string, raw.hasPrefix("0x") else { throw Failure.malformed }
        let bytes = try TronIdentity.hex(String(raw.dropFirst(2)))
        if bytes.isEmpty { return .init(coverage: .checked) }
        if bytes.count == 23, bytes.prefix(3) == Data([0xef, 0x01, 0x00]) {
            return .init(coverage: .checked, findings: [.delegatedCode])
        }
        let proxyHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard Self.safeProxySHA256.contains(proxyHash) else {
            return .init(coverage: .notDiscoverable, findings: [.contractControlled])
        }
        let master = try await rpc(endpoint, "eth_call", .array([
            .object(["to": .string(address), "data": .string("0xa619486e")]), block]))
        guard let masterHex = master.string else { throw Failure.malformed }
        let masterBytes = try Self.abi(masterHex)
        guard masterBytes.count == 32, masterBytes.prefix(12).allSatisfy({ $0 == 0 }) else { throw Failure.malformed }
        let singleton = "0x" + TronSendCrypto.hex(masterBytes.suffix(20))
        let implementation = try await rpc(endpoint, "eth_getCode", .array([.string(singleton), block]))
        guard let implementationHex = implementation.string else { throw Failure.malformed }
        let implementationBytes = try Self.abi(implementationHex)
        guard Self.safeImplementationKeccak.contains(TronSendCrypto.hex(TronSendCrypto.keccak(implementationBytes))) else {
            return .init(coverage: .notDiscoverable, findings: [.contractControlled])
        }
        async let owners = rpc(endpoint, "eth_call", .array([
            .object(["to": .string(address), "data": .string("0xa0e67e2b")]), block]))
        async let threshold = rpc(endpoint, "eth_call", .array([
            .object(["to": .string(address), "data": .string("0xe75235b8")]), block]))
        return try await Self.safePolicy(owners: owners, threshold: threshold)
    }

    static func abi(_ hex: String) throws -> Data {
        guard hex.hasPrefix("0x"), hex.count <= 131_074 else { throw Failure.malformed }
        return try TronIdentity.hex(String(hex.dropFirst(2)))
    }
    static func word(_ bytes: Data, at offset: Int) throws -> Int {
        guard offset >= 0, bytes.count >= offset + 32,
              bytes[offset..<(offset + 28)].allSatisfy({ $0 == 0 }) else { throw Failure.malformed }
        return bytes[(offset + 28)..<(offset + 32)].reduce(0) { ($0 << 8) | Int($1) }
    }
    static func safePolicy(owners: J, threshold: J) throws -> PublicSigningAssessment {
        guard let ownersHex = owners.string, let thresholdHex = threshold.string else { throw Failure.malformed }
        let bytes = try abi(ownersHex), thresholdBytes = try abi(thresholdHex)
        guard thresholdBytes.count == 32, try word(bytes, at: 0) == 32 else { throw Failure.malformed }
        let count = try word(bytes, at: 32), required = try word(thresholdBytes, at: 0)
        guard (1...1024).contains(count), (1...count).contains(required), bytes.count == 64 + count * 32 else { throw Failure.malformed }
        var seen = Set<Data>()
        for i in 0..<count {
            let offset = 64 + i * 32
            let owner = bytes.subdata(in: (offset + 12)..<(offset + 32))
            guard bytes[offset..<(offset + 12)].allSatisfy({ $0 == 0 }),
                  owner.contains(where: { $0 != 0 }), seen.insert(owner).inserted else { throw Failure.malformed }
        }
        return .init(coverage: .checked, findings: count > 1 ? [.multisig] : [.contractControlled, .differentSigner])
    }
}
