import Foundation
import WalletCore

/// Relay and Hub share SS58 addresses but are different ledgers.
/// Callers must verify genesis before reading funds or preparing a signature.
enum PolkadotLedger: Sendable {
    case assetHub, relay
    var genesis: String {
        switch self {
        case .assetHub: "0x68d56f15f85d3136970ec16946040bc1752654e906147f7e43e9d539d7c3de2f"
        case .relay: "0x91b171bb158e2d3848fa23a9f1c25182fb8e20313b2c1eb49219da7a70ce90c3"
        }
    }
    var runtimeName: String { self == .assetHub ? "statemint" : "polkadot" }
}

enum PolkadotRPCError: Error { case wrongLedger, unsupportedRuntime, invalidAccount, invalidResponse }

struct PolkadotRuntime: Decodable, Sendable {
    let specName: String
    let specVersion: UInt32
    let transactionVersion: UInt32
}

struct PolkadotAccountBalance: Equatable, Sendable {
    let nonce: UInt32
    let free: String
    let reserved: String
    let frozen: String
    /// This excludes reserved funds. Fee and keep-alive requirements must still
    /// be applied by a transaction planner; this is not a maximum-send quote.
    var unlocked: String {
        (try? SendAtomicAmount.subtract(free, frozen)) ?? "0"
    }

    static func decode(_ encoded: String) throws -> Self {
        guard encoded.hasPrefix("0x"), let bytes = Data(hexString: String(encoded.dropFirst(2))),
              bytes.count == 80 else { throw PolkadotRPCError.invalidResponse }
        let nonce = bytes.prefix(4).enumerated().reduce(UInt32(0)) { result, value in
            result | (UInt32(value.element) << (value.offset * 8))
        }
        func number(_ offset: Int) throws -> String {
            try SendAtomicAmount.decimalFromHexQuantity("0x" + Data(bytes[offset..<(offset + 16)].reversed()).hexString)
        }
        return try Self(nonce: nonce, free: number(16), reserved: number(32), frozen: number(48))
    }
}

actor PolkadotRPCClient {
    private let transport: AnkrRPCTransport
    private let ledger: PolkadotLedger
    private var verifiedGenesis = false

    init(configuration: AnkrConfiguration, ledger: PolkadotLedger, session: URLSession? = nil) {
        self.ledger = ledger
        transport = AnkrRPCTransport(endpoint: ledger == .assetHub
            ? configuration.polkadotAssetHubJSONRPCEndpoint : configuration.polkadotRelayJSONRPCEndpoint,
            session: session)
    }

    func accountBalance(address: String) async throws -> (blockHash: String, balance: PolkadotAccountBalance) {
        try await verifyLedger()
        let block: String = try await transport.call(method: "chain_getFinalizedHead", parameters: [String]())
        guard Self.isHash(block) else { throw PolkadotRPCError.invalidResponse }
        let runtime: PolkadotRuntime = try await transport.call(method: "state_getRuntimeVersion", parameters: [block])
        // The fixed SCALE AccountInfo layout is only verified for this runtime.
        // Reject upgrades until metadata decoding has been revalidated.
        guard runtime.specName == ledger.runtimeName, runtime.specVersion == 2_005_000 else {
            throw PolkadotRPCError.unsupportedRuntime
        }
        let key = try Self.accountStorageKey(address: address)
        let raw: String = try await transport.call(method: "state_getStorage", parameters: [key, block])
        return (block, try PolkadotAccountBalance.decode(raw))
    }

    private func verifyLedger() async throws {
        if verifiedGenesis { return }
        let genesis: String = try await transport.call(method: "chain_getBlockHash", parameters: [0])
        guard genesis == ledger.genesis else { throw PolkadotRPCError.wrongLedger }
        verifiedGenesis = true
    }

    static func accountStorageKey(address: String) throws -> String {
        guard let data = Base58.decodeNoCheck(string: address), data.count == 35, data.first == 0 else {
            throw PolkadotRPCError.invalidAccount
        }
        let payload = Data(data.prefix(33))
        let checksum = Hash.blake2b(data: Data("SS58PRE".utf8) + payload, size: 64).prefix(2)
        guard data.suffix(2) == checksum else { throw PolkadotRPCError.invalidAccount }
        let account = Data(payload.dropFirst())
        return "0x26aa394eea5630e07c48ae0c9558cef7b99d880ec681799c0cf30e8886371da9"
            + Hash.blake2b(data: account, size: 16).hexString + account.hexString
    }

    private static func isHash(_ value: String) -> Bool {
        value.hasPrefix("0x") && value.count == 66 && value.dropFirst(2).allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}
