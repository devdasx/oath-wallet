import Foundation
import OathDiagnostics

/// Display metadata only. A name is never evidence of safety or permission to sign.
/// The full chain/address remains the identity used by every permission operation.
public struct ContractIdentity: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case catalog, onChain, sourcify }
    public let network: String, address: String, name: String
    public let symbol: String?
    public let decimals: Int?
    public let source: Source
    public let checkedAt: Date
    public var id: String { network + ":" + address }
    public init(network: String, address: String, name: String, symbol: String? = nil,
                decimals: Int? = nil, source: Source, checkedAt: Date = .now) throws {
        self.network = network
        self.address = try Self.canonical(address, network: network)
        guard let name = Self.clean(name), decimals.map({ (0...255).contains($0) }) ?? true,
              checkedAt.timeIntervalSince1970.isFinite else { throw PermissionError.malformed }
        self.name = name; self.symbol = symbol.flatMap(Self.clean); self.decimals = decimals
        self.source = source; self.checkedAt = checkedAt
    }
    public static func canonical(_ address: String, network: String) throws -> String {
        if EVMSendNetwork(rawValue: network) != nil || network == "arc" { return try EVMSendIdentity.address(address) }
        if network == "tron" { return try TronIdentity.address(address) }
        guard network == "solana", SolanaIdentity.isAddress(address) else { throw PermissionError.unsupported }
        return address
    }
    public static func clean(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 256,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0)
                  || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) else { return nil }
        return text
    }
    /// Optional ABI metadata can be absent or use the old bytes32 representation.
    /// A malformed/absent optional value is not a failed allowance read.
    static func abiText(_ raw: String?) -> String? {
        guard let raw, raw.count <= 1154, let data = try? TronIdentity.hex(raw) else { return nil }
        let bytes: Data
        if data.count == 32 { bytes = Data(data.prefix { $0 != 0 }) }
        else {
            guard data.count >= 64, data.prefix(31).allSatisfy({ $0 == 0 }), data[31] == 32,
                  data[32..<63].allSatisfy({ $0 == 0 }) else { return nil }
            let count = Int(data[63])
            guard count > 0, count <= data.count - 64 else { return nil }
            bytes = data.subdata(in: 64..<(64 + count))
        }
        return String(data: bytes, encoding: .utf8).flatMap(clean)
    }
}

extension WalletPermission {
    /// Permit2 stores the approved token separately from the Permit2 dispatcher.
    /// Account-control entries describe the delegate, not the owner's own account.
    public var identityAddress: String {
        switch kind {
        case .permit2, .permit2Nonce: tokenID ?? contract
        case .accountControl, .delegation: spender
        default: contract
        }
    }
    public var identityKey: String { Self.identityKey(network: network, address: identityAddress) }
    public var spenderIdentityKey: String { Self.identityKey(network: network, address: spender) }
    public static func identityKey(network: String, address: String) -> String {
        network + ":" + ((EVMSendNetwork(rawValue: network) != nil || network == "arc") ? address.lowercased() : address)
    }
}

/// On-demand access to the public verified-contract registry, rather than a
/// finite bundled list. Only compilation.name is fetched, never source or ABI.
/// API: https://docs.sourcify.dev/docs/api/
public struct ContractIdentityClient: Sendable {
    private let transport: any AnkrTransport
    public init(transport: (any AnkrTransport)? = nil) { self.transport = transport ?? ContractIdentityHTTPTransport() }
    public func verifiedContract(network: EVMSendNetwork, address: String) async throws -> ContractIdentity? {
        let address = try EVMSendIdentity.address(address)
        let url = URL(string: "https://sourcify.dev/server/v2/contract/\(network.chainID)/\(address)?fields=compilation.name")!
        var request = URLRequest(url: url); request.timeoutInterval = 8
        let (data, status) = try await transport.send(request)
        // Missing verification and unsupported chains are expected optional metadata.
        if status == 404 { return nil }
        DiagnosticHTTP.response(data, status: status, request: request)
        guard status == 200 else { throw AnkrError.http(status) }
        guard data.count <= 65_536 else { throw AnkrError.responseTooLarge }
        let json = try JSONDecoder().decode(SolanaJSON.self, from: data)
        guard json["chainId"].string == String(network.chainID),
              json["address"].string?.lowercased() == address else { throw AnkrError.wrongChain }
        guard ["exact_match", "match"].contains(json["runtimeMatch"].string ?? "") else { return nil }
        guard let name = json["compilation"]["name"].string.flatMap(ContractIdentity.clean) else { return nil }
        return try .init(network: network.rawValue, address: address, name: name, source: .sourcify)
    }
}

private struct ContractIdentityHTTPTransport: AnkrTransport {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = 12
        session = URLSession(configuration: config)
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AnkrError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 65_536 else { throw AnkrError.responseTooLarge }
                data.append(byte)
            }
            // The caller reports unexpected HTTP/provider envelopes. A missing
            // public registry entry (404) is an expected lookup miss.
            return (data, http.statusCode)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            OathDiagnostics.record(error, component: "permissions", operation: "identity_transport")
            throw error
        }
    }
}
