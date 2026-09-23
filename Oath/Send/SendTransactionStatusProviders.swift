import CryptoKit
import Foundation
import WalletCore

enum SendTransactionStatusValidation {
    static func isHexHash(
        _ value: String,
        byteCount: Int,
        allowsPrefix: Bool
    ) -> Bool {
        let payload: Substring
        if allowsPrefix, value.hasPrefix("0x") {
            payload = value.dropFirst(2)
        } else {
            payload = value[...]
        }
        return payload.utf8.count == byteCount * 2
            && payload.utf8.allSatisfy { byte in
                (48...57).contains(byte)
                    || (65...70).contains(byte)
                    || (97...102).contains(byte)
            }
    }

    static func isBase58Hash(
        _ value: String,
        byteCount: Int
    ) -> Bool {
        guard !value.isEmpty,
              let decoded = Base58.decodeNoCheck(string: value),
              decoded.count == byteCount else {
            return false
        }
        return Base58.encodeNoCheck(data: decoded) == value
    }
}

struct BitcoinFamilyTransactionStatusProvider: Sendable {
    private let electrum: BitcoinFamilyElectrumClient
    private let bitcoinStatus = SendBitcoinExactStatus()

    init(
        electrum: BitcoinFamilyElectrumClient = .shared
    ) {
        self.electrum = electrum
    }

    func status(
        chain: BitcoinFamilyChain,
        transactionHash: String,
        accountAddress: String
    ) async throws -> SendTransactionNetworkStatus {
        return try await exactStatus(chain: chain, transactionHash: transactionHash)
    }

    func exactStatus(chain: BitcoinFamilyChain, transactionHash: String) async throws -> SendTransactionNetworkStatus {
        let hash = transactionHash.lowercased()
        guard SendTransactionStatusValidation.isHexHash(hash, byteCount: 32, allowsPrefix: false) else {
            throw SendTransactionStatusProviderError.invalidTransactionHash(networkID: chain.networkID)
        }
        if chain == .bitcoin { return try await bitcoinStatus.status(hash: hash) }
        return try await electrum.transactionStatus(chain: chain, hash: hash)
    }

    static func verboseStatus(_ value: JSONValue, expectedHash: String, networkID: String) throws -> SendTransactionNetworkStatus {
        guard let object = value.object,
              object["txid"]?.string?.caseInsensitiveCompare(expectedHash) == .orderedSame,
              object["vin"]?.array != nil, object["vout"]?.array != nil else {
            throw SendTransactionStatusProviderError.invalidResponse(networkID: networkID, code: "verbose_transaction")
        }
        guard let raw = object["confirmations"] else { return .pending }
        guard let confirmations = raw.exactInt64 else {
            throw SendTransactionStatusProviderError.invalidResponse(networkID: networkID, code: "confirmations")
        }
        if confirmations < 0 { return .failed }
        guard confirmations > 0 else { return .pending }
        guard let block = object["blockhash"]?.string,
              SendTransactionStatusValidation.isHexHash(block, byteCount: 32, allowsPrefix: false) else {
            throw SendTransactionStatusProviderError.invalidResponse(networkID: networkID, code: "block_hash")
        }
        return .confirmed
    }

    /// Legacy history lookup retained for provider diagnostics and migration tests.
    func historyStatus(chain: BitcoinFamilyChain, transactionHash: String, accountAddress: String) async throws -> SendTransactionNetworkStatus {
        let address = accountAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard chain.coin.validate(address: address) else {
            throw SendTransactionStatusProviderError.invalidAccount(
                networkID: chain.networkID
            )
        }
        let script = BitcoinScript.lockScriptForAddress(
            address: address,
            coin: chain.coin
        ).data
        guard !script.isEmpty else {
            throw SendTransactionStatusProviderError.invalidAccount(
                networkID: chain.networkID
            )
        }
        let scriptHash = Data(SHA256.hash(data: script))
            .reversed()
            .map { String(format: "%02x", $0) }
            .joined()
        return try await status(
            chain: chain,
            transactionHash: transactionHash,
            scriptHash: scriptHash
        )
    }

    func status(
        chain: BitcoinFamilyChain,
        transactionHash: String,
        scriptHash: String
    ) async throws -> SendTransactionNetworkStatus {
        let hash = transactionHash.lowercased()
        guard SendTransactionStatusValidation.isHexHash(
            hash,
            byteCount: 32,
            allowsPrefix: false
        ), SendTransactionStatusValidation.isHexHash(
            scriptHash,
            byteCount: 32,
            allowsPrefix: false
        ) else {
            throw SendTransactionStatusProviderError
                .invalidTransactionHash(networkID: chain.networkID)
        }
        let value = try await electrum.call(
            chain: chain,
            method: "blockchain.scripthash.get_history",
            params: [AnyEncodable(scriptHash)],
            maximumResponseBytes:
                BitcoinFamilyElectrumClient.maximumHistoryResponseBytes
        )
        guard let history = value.array else {
            throw SendTransactionStatusProviderError.invalidResponse(
                networkID: chain.networkID,
                code: "history"
            )
        }
        for item in history {
            guard let object = item.object,
                  let candidate = object["tx_hash"]?.string,
                  let height = object["height"]?.exactInt64 else {
                throw SendTransactionStatusProviderError.invalidResponse(
                    networkID: chain.networkID,
                    code: "history_item"
                )
            }
            if candidate.caseInsensitiveCompare(hash) == .orderedSame {
                return height > 0 ? .confirmed : .pending
            }
        }
        return .notFound
    }
}

struct SolanaTransactionStatusProvider: Sendable {
    private let transport: SolanaRPCTransport

    init(transport: SolanaRPCTransport = .shared) {
        self.transport = transport
    }

    func status(
        signature: String
    ) async throws -> SendTransactionNetworkStatus {
        guard SendTransactionStatusValidation.isBase58Hash(
            signature,
            byteCount: 64
        ) else {
            throw SendTransactionStatusProviderError
                .invalidTransactionHash(
                    networkID: SolanaConstants.networkID
                )
        }
        return try await transport.transactionStatus(signature: signature)
    }

    static func status(
        from result: SolanaJSONValue
    ) throws -> SendTransactionNetworkStatus {
        guard let values = result.object?["value"]?.array,
              values.count == 1 else {
            throw SendTransactionStatusProviderError.invalidResponse(
                networkID: SolanaConstants.networkID,
                code: "signature_statuses"
            )
        }
        guard case let .object(status) = values[0] else {
            if case .null = values[0] { return .notFound }
            throw SendTransactionStatusProviderError.invalidResponse(
                networkID: SolanaConstants.networkID,
                code: "signature_status"
            )
        }
        guard let error = status["err"] else {
            throw SendTransactionStatusProviderError.invalidResponse(
                networkID: SolanaConstants.networkID,
                code: "signature_error"
            )
        }
        if case .null = error {
            // Continue to the provider's explicit commitment state.
        } else {
            return .failed
        }
        switch status["confirmationStatus"]?.string {
        case "confirmed", "finalized":
            return .confirmed
        case "processed":
            return .pending
        default:
            throw SendTransactionStatusProviderError.invalidResponse(
                networkID: SolanaConstants.networkID,
                code: "confirmation_status"
            )
        }
    }
}

struct TronTransactionStatusProvider: Sendable {
    private let transport: TronAPITransport

    init(transport: TronAPITransport = .shared) {
        self.transport = transport
    }

    func status(
        transactionHash: String
    ) async throws -> SendTransactionNetworkStatus {
        let hash = transactionHash.lowercased()
        guard SendTransactionStatusValidation.isHexHash(
            hash,
            byteCount: 32,
            allowsPrefix: false
        ) else {
            throw SendTransactionStatusProviderError
                .invalidTransactionHash(networkID: TronConstants.networkID)
        }
        let envelope: TronTransactionStatusEnvelope<TronTransactionInfoStatus> = try await transport.rest(
            path: "walletsolidity/gettransactioninfobyid",
            body: ["value": hash]
        )
        let response = envelope.value
        if response.id == nil {
            guard envelope.isEmpty else {
                throw SendTransactionStatusProviderError.invalidResponse(
                    networkID: TronConstants.networkID, code: "transaction_info_identity")
            }
            // The solidity node only indexes irreversible blocks. Check the
            // full node before classifying an unconfirmed transaction as absent.
            let presence: TronTransactionStatusEnvelope<TronTransactionPresence> = try await transport.rest(
                path: "wallet/gettransactionbyid", body: ["value": hash])
            let transaction = presence.value
            guard let found = transaction.txID else {
                guard presence.isEmpty else {
                    throw SendTransactionStatusProviderError.invalidResponse(
                        networkID: TronConstants.networkID, code: "transaction_presence_identity")
                }
                return .notFound
            }
            guard found.caseInsensitiveCompare(hash) == .orderedSame else {
                throw SendTransactionStatusProviderError.invalidResponse(
                    networkID: TronConstants.networkID, code: "transaction_identity")
            }
            return .pending
        }
        return try Self.status(from: response, expectedHash: hash)
    }

    static func status(
        from response: TronTransactionInfoStatus,
        expectedHash: String
    ) throws -> SendTransactionNetworkStatus {
        guard let hash = response.id else { return .notFound }
        guard hash.caseInsensitiveCompare(expectedHash) == .orderedSame,
              let blockNumber = response.blockNumber,
              blockNumber > 0 else {
            throw SendTransactionStatusProviderError.invalidResponse(
                networkID: TronConstants.networkID,
                code: "transaction_info"
            )
        }
        for result in [response.result, response.receipt?.result]
            .compactMap({ $0?.uppercased() }) {
            if result != "SUCCESS" {
                return .failed
            }
        }
        return .confirmed
    }
}

private struct TronTransactionPresence: Decodable, Sendable {
    let txID: String?
}

/// Tron returns {} for absence, but can also return HTTP 200 with an Error
/// payload. Only an empty object is an authoritative missing response.
private struct TronTransactionStatusEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value
    let isEmpty: Bool

    init(from decoder: Decoder) throws {
        let payload = try JSONValue(from: decoder)
        guard let object = payload.object,
              !object.keys.contains(where: { $0.lowercased() == "error" }),
              object.isEmpty || object["id"]?.string != nil || object["txID"]?.string != nil else {
            throw SendTransactionStatusProviderError.invalidResponse(
                networkID: TronConstants.networkID, code: "transaction_envelope")
        }
        isEmpty = object.isEmpty
        value = try Value(from: decoder)
    }
}

struct TronTransactionInfoStatus: Decodable, Sendable {
    struct Receipt: Decodable, Sendable {
        let result: String?
    }

    let id: String?
    let blockNumber: Int64?
    let result: String?
    let receipt: Receipt?
}

struct NEARTransactionStatusProvider: Sendable {
    private let transports: [NEARJSONRPCTransport]
    private let endpoints: [URL]?

    init(transport: NEARJSONRPCTransport? = nil) throws {
        transports = [try transport ?? NEARJSONRPCTransport()]
        endpoints = nil
    }

    init(publicEndpoints: [URL]) throws {
        guard !publicEndpoints.isEmpty else { throw NEARProviderError.invalidConfiguration }
        endpoints = publicEndpoints
        transports = try publicEndpoints.map { try NEARJSONRPCTransport(endpoint: $0) }
    }

    func status(
        transactionHash: String,
        senderAccountID: String
    ) async throws -> SendTransactionNetworkStatus {
        guard SendTransactionStatusValidation.isBase58Hash(
            transactionHash,
            byteCount: 32
        ) else {
            throw SendTransactionStatusProviderError
                .invalidTransactionHash(networkID: NEARConstants.networkID)
        }
        guard NEARAddress.isValid(senderAccountID) else {
            throw SendTransactionStatusProviderError.invalidAccount(
                networkID: NEARConstants.networkID
            )
        }
        if let endpoints {
            let attempts = endpoints.enumerated().map { index, endpoint in
                let transport = transports[index]
                return AdaptiveProviderAttempt(endpoint: AdaptiveProviderEndpoint(
                    serviceID: "near_exact_transaction_status", endpointURL: endpoint, baselinePriority: index)) {
                    try await Self.read(transport: transport, transactionHash: transactionHash,
                                        senderAccountID: senderAccountID)
                }
            }
            return try await SendStatusReadResolver.resolve(attempts: attempts)
        }
        return try await Self.read(transport: transports[0], transactionHash: transactionHash,
                                   senderAccountID: senderAccountID)
    }

    private static func read(transport: NEARJSONRPCTransport, transactionHash: String,
                             senderAccountID: String) async throws -> SendTransactionNetworkStatus {
        let result: NEARJSONValue
        do {
            result = try await transport.request(
                method: "tx",
                parameters: .object([
                    "tx_hash": .string(transactionHash),
                    "sender_account_id": .string(senderAccountID),
                    "wait_until": .string("EXECUTED")
                ])
            )
        } catch let error as NEARProviderError {
            if case let .rpc(_, message) = error,
               message == "unknown_transaction" {
                return .notFound
            }
            throw error
        }
        return try Self.status(
            from: result,
            expectedHash: transactionHash
        )
    }

    static func status(
        from result: NEARJSONValue,
        expectedHash: String
    ) throws -> SendTransactionNetworkStatus {
        guard let object = result.objectValue,
              let transaction = object["transaction"]?.objectValue,
              transaction["hash"]?.stringValue == expectedHash,
              let status = object["status"]?.objectValue,
              let execution = object["final_execution_status"]?
                .stringValue else {
            throw SendTransactionStatusProviderError.invalidResponse(
                networkID: NEARConstants.networkID,
                code: "transaction_status"
            )
        }
        if status["Failure"] != nil { return .failed }
        guard status["SuccessValue"] != nil
                || status["SuccessReceiptId"] != nil else {
            return .pending
        }
        switch execution {
        case "EXECUTED", "FINAL":
            return .confirmed
        case "NONE", "INCLUDED", "EXECUTED_OPTIMISTIC",
             "INCLUDED_FINAL", "NOT_STARTED", "STARTED":
            return .pending
        default:
            throw SendTransactionStatusProviderError.invalidResponse(
                networkID: NEARConstants.networkID,
                code: "execution_status"
            )
        }
    }
}
