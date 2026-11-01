import Foundation
import CryptoKit
internal import BitcoinDevKit

public enum BitcoinConnectNetwork: String, Codable, CaseIterable, Sendable {
    case mainnet, testnet, testnet4, signet
    public var chain: String {
        let reference = switch self {
        case .mainnet: "000000000019d6689c085ae165831e93"
        case .testnet: "000000000933ea01ad0ee984209779ba"
        case .testnet4: "00000000da84f2bafbbc53dee25a72ae"
        case .signet: "00000008819873e925422c1ff0f99f7c"
        }
        return "bip122:" + reference
    }
    public init?(chain: String) {
        guard let value = Self.allCases.first(where: { $0.chain == chain }) else { return nil }; self = value
    }
    public var name: String {
        switch self { case .mainnet: "Bitcoin"; case .testnet: "Bitcoin Testnet"; case .testnet4: "Bitcoin Testnet4"; case .signet: "Bitcoin Signet" }
    }
    var bdk: Network {
        switch self { case .mainnet: .bitcoin; case .testnet: .testnet; case .testnet4: .testnet4; case .signet: .signet }
    }
    public var explorer: String { "https://mempool.space/" + (self == .mainnet ? "" : rawValue + "/") }
    public func script(_ address: String) throws -> Data {
        guard address.utf8.count <= 128 else { throw BitcoinConnectError.invalidRequest }
        return try Address(address: address, network: bdk).scriptPubkey().toBytes()
    }
    public func address(script: Data) throws -> String {
        try Address.fromScript(script: Script(rawOutputScript: script), network: bdk).description
    }
    /// A connection shares the same public scripts and derivation paths as the
    /// selected account. Network encodings never change which key owns a script.
    public func address(mainnetAddress: String) throws -> String {
        try address(script: BitcoinConnectNetwork.mainnet.script(mainnetAddress))
    }
    public func matchesAccount(_ stored: String, _ requested: String) -> Bool {
        guard let right = try? script(requested) else { return false }
        if let left = try? script(stored) { return left == right }
        guard self != .mainnet, let left = try? Self.mainnet.script(stored) else { return false }
        return left == right
    }
}

public enum BitcoinConnectError: String, Error, Sendable {
    case invalidRequest, wrongAccount, unsupported, invalidPSBT, wrongInput, invalidFee
    case insufficientFunds, changed, unavailable, tooLarge, expired, busy
}

public struct BitcoinConnectRequest: Codable, Equatable, Sendable {
    public static let methods: Set<String> = ["getAccountAddresses", "sendTransfer", "signPsbt", "signMessage"]
    public static let signingMethods = methods.subtracting(["getAccountAddresses"])
    public static let events = ["bip122_addressesChanged"]
    public struct Input: Codable, Equatable, Sendable {
        public let address: String
        public let index: Int
        public let sighashTypes: [UInt32]?
        public init(address: String, index: Int, sighashTypes: [UInt32]? = nil) {
            self.address = address; self.index = index; self.sighashTypes = sighashTypes
        }
    }
    public let network: BitcoinConnectNetwork
    public let method: String
    public let account: String
    public let recipientAddress: String?
    public let amount: String?
    public let changeAddress: String?
    public let memo: String?
    public let psbt: String?
    public let signInputs: [Input]?
    public let broadcast: Bool?
    public let message: String?
    public let address: String?
    public let `protocol`: String?
    public let intentions: [String]?
    public var broadcasts: Bool { method == "sendTransfer" || (method == "signPsbt" && broadcast == true) }
    public var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { Data(SHA256.hash(data: $0)).hex } ?? ""
    }
    public func validate() throws {
        // Persisted requests pass through the same bounds as new peer requests.
        guard try Self(method: method, chain: network.chain, account: account,
                       params: JSONEncoder().encode(self)) == self else { throw BitcoinConnectError.changed }
    }
    public init(method: String, chain: String, account: String, params: Data) throws {
        guard let network = BitcoinConnectNetwork(chain: chain), Self.methods.contains(method), params.count <= 750_000 else { throw BitcoinConnectError.unsupported }
        struct Parameters: Decodable {
            let account: String
            let recipientAddress: String?, amount: String?, changeAddress: String?, memo: String?, psbt: String?
            let signInputs: [Input]?, broadcast: Bool?, message: String?, address: String?, `protocol`: String?, intentions: [String]?
        }
        let value: Parameters
        do { value = try JSONDecoder().decode(Parameters.self, from: params) }
        catch {
            // diagnostics: bitcoin-connect-parameter-validation
            // Malformed peer parameters are rejected before any account or network operation.
            throw BitcoinConnectError.invalidRequest
        }
        guard value.account == account else { throw BitcoinConnectError.wrongAccount }
        _ = try network.script(account)
        self.network = network; self.method = method; self.account = account
        recipientAddress = value.recipientAddress; amount = value.amount; changeAddress = value.changeAddress
        memo = value.memo; psbt = value.psbt; signInputs = value.signInputs; broadcast = value.broadcast
        message = value.message; address = value.address; self.protocol = value.protocol; intentions = value.intentions
        switch method {
        case "sendTransfer":
            guard let amount, !amount.isEmpty, amount.utf8.allSatisfy({ (48...57).contains($0) }),
                  let sats = UInt64(amount), sats > 0, sats <= UInt64(BitcoinSendPlan.maximumMoney), let recipientAddress else { throw BitcoinConnectError.invalidRequest }
            _ = try network.script(recipientAddress)
            if let changeAddress { _ = try network.script(changeAddress) }
            if let memo { guard memo.count <= 160, memo.count % 2 == 0, Data(hex: memo) != nil else { throw BitcoinConnectError.invalidRequest } }
        case "signPsbt":
            guard let psbt, let bytes = Data(base64Encoded: psbt), bytes.count <= BitcoinConnectPSBT.maximumBytes,
                  let signInputs, !signInputs.isEmpty, signInputs.count <= 128,
                  Set(signInputs.map(\.index)).count == signInputs.count else { throw BitcoinConnectError.invalidPSBT }
            for input in signInputs {
                guard input.index >= 0, input.index < 128,
                      input.sighashTypes == nil || (!input.sighashTypes!.isEmpty && input.sighashTypes!.allSatisfy({ [0, 1].contains($0) })) else { throw BitcoinConnectError.unsupported }
                _ = try network.script(input.address)
            }
        case "signMessage":
            guard let message, !message.isEmpty, message.utf8.count <= 16_384,
                  value.protocol == nil || ["ecdsa", "bip322"].contains(value.protocol!) else { throw BitcoinConnectError.invalidRequest }
            _ = try network.script(address ?? account)
        case "getAccountAddresses":
            guard intentions == nil || (intentions!.count <= 8 && intentions!.allSatisfy({ $0.utf8.count <= 32 })) else { throw BitcoinConnectError.invalidRequest }
        default: throw BitcoinConnectError.unsupported
        }
    }
}

public struct BitcoinConnectAddress: Codable, Equatable, Sendable {
    public let address: String
    public let path: String
    public let intention: String
    public init(_ derived: BitcoinDerivedAddress, network: BitcoinConnectNetwork) throws {
        guard let script = Data(hex: derived.script) else { throw BitcoinConnectError.wrongAccount }
        address = try network.address(script: script)
        path = derived.path; intention = "payment"
    }
}
