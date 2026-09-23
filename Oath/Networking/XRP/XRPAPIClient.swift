import Foundation

actor XRPAPIClient {
    static let shared = XRPAPIClient()

    private let transport: XRPJSONRPCTransport?

    init(transport: XRPJSONRPCTransport? = nil) {
        self.transport = transport ?? (try? XRPJSONRPCTransport())
    }

    func loadSnapshot(
        material: XRPAccountMaterial,
        historyLedgerMinimum: Int64? = nil,
        onBalances:
            (@Sendable (XRPWalletSnapshot) async throws -> Void)? = nil
    ) async throws -> XRPWalletSnapshot {
        guard XRPAddress.validatedClassic(material.address) != nil else {
            throw XRPProviderError.invalidAddress
        }
        guard let transport else {
            throw XRPProviderError.missingConfiguration
        }

        // The native balance and issued-currency inventory are independent
        // XRPL reads. Start both immediately so token balances do not inherit
        // the full account_info latency before account_lines even begins.
        async let issuedBalanceTask = trustLineBalances(
            address: material.address,
            transport: transport
        )
        let nativeLoad = try await nativeBalance(
            address: material.address,
            transport: transport
        )
        let nativeSnapshot = XRPWalletSnapshot(
            material: material,
            balances: [nativeLoad.balance],
            history: [],
            balancesAreAuthoritative: !nativeLoad.accountExists,
            historyIsAuthoritative: false,
            providerFailureCodes: [],
            historyLedgerWatermark: nil,
            successfulBalanceAssetIDs: [
                XRPConstants.nativeAssetID
            ]
        )
        try await onBalances?(nativeSnapshot)
        try Task.checkCancellation()

        var balanceLoad: XRPBalanceLoad
        if nativeLoad.accountExists {
            do {
                let issuedBalances = try await issuedBalanceTask
                balanceLoad = XRPBalanceLoad(
                    balances: [nativeLoad.balance] + issuedBalances.balances,
                    isComplete: issuedBalances.isComplete,
                    failureCodes: issuedBalances.failureCodes
                )
                try await onBalances?(
                    XRPWalletSnapshot(
                        material: material,
                        balances: balanceLoad.balances,
                        history: [],
                        balancesAreAuthoritative: balanceLoad.isComplete,
                        historyIsAuthoritative: false,
                        providerFailureCodes: balanceLoad.failureCodes,
                        historyLedgerWatermark: nil,
                        successfulBalanceAssetIDs: Set(
                            balanceLoad.balances.map(\.assetID)
                        )
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The native balance is independently authoritative. Keep the
                // full inventory non-authoritative so an unavailable trust-line
                // provider can never clear previously persisted issued assets.
                balanceLoad = XRPBalanceLoad(
                    balances: [nativeLoad.balance],
                    isComplete: false,
                    failureCodes: [Self.failureCode(error)]
                )
            }
        } else {
            // account_lines independently reports actNotFound for an inactive
            // account. Consume that already-running read without converting a
            // valid authoritative zero balance into a provider failure.
            do {
                _ = try await issuedBalanceTask
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // account_info is the authority for account existence.
            }
            balanceLoad = XRPBalanceLoad(
                balances: [nativeLoad.balance],
                isComplete: true,
                failureCodes: []
            )
        }
        try Task.checkCancellation()

        do {
            let history = try await history(
                address: material.address,
                transport: transport,
                ledgerMinimum: historyLedgerMinimum
            )
            return XRPWalletSnapshot(
                material: material,
                balances: balanceLoad.balances,
                history: history.items,
                balancesAreAuthoritative: balanceLoad.isComplete,
                historyIsAuthoritative: history.isComplete,
                providerFailureCodes: balanceLoad.failureCodes
                    + history.failureCodes,
                historyLedgerWatermark: history.latestValidatedLedger,
                successfulBalanceAssetIDs: Set(
                    balanceLoad.balances.map(\.assetID)
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return XRPWalletSnapshot(
                material: material,
                balances: balanceLoad.balances,
                history: [],
                balancesAreAuthoritative: balanceLoad.isComplete,
                historyIsAuthoritative: false,
                providerFailureCodes: balanceLoad.failureCodes
                    + [Self.failureCode(error)],
                historyLedgerWatermark: nil,
                successfulBalanceAssetIDs: Set(
                    balanceLoad.balances.map(\.assetID)
                )
            )
        }
    }

    func accountState(address: String) async throws -> XRPAccountState {
        guard XRPAddress.validatedClassic(address) != nil else {
            throw XRPProviderError.invalidAddress
        }
        guard let transport else {
            throw XRPProviderError.missingConfiguration
        }
        let result = try await transport.request(
            method: "account_info",
            parameters: [
                "account": .string(address),
                "ledger_index": .string("validated"),
                "strict": .boolean(true)
            ]
        )
        guard let data = result["account_data"]?.objectValue,
              let sequence = data["Sequence"]?.integerValue,
              sequence >= 0,
              sequence <= Int64(UInt32.max),
              let balance = data["Balance"]?.stringValue,
              ExactDecimalText.canonicalUnsignedInteger(balance) != nil,
              let ownerCount = data["OwnerCount"]?.integerValue,
              ownerCount >= 0,
              ownerCount <= Int64(UInt32.max),
              let flags = data["Flags"]?.integerValue,
              flags >= 0,
              flags <= Int64(UInt32.max)
        else {
            throw XRPProviderError.invalidResponse("account_info")
        }
        let transferRateValue = data["TransferRate"]?.integerValue ?? 0
        guard transferRateValue == 0
                || (transferRateValue >= 1_000_000_000
                    && transferRateValue <= Int64(UInt32.max))
        else {
            throw XRPProviderError.invalidResponse("transfer_rate")
        }
        return XRPAccountState(
            sequence: UInt32(sequence),
            balanceDrops: balance,
            ownerCount: UInt32(ownerCount),
            flags: UInt32(flags),
            transferRate: transferRateValue == 0
                ? 1_000_000_000 : UInt32(transferRateValue)
        )
    }

    func optionalAccountState(address: String) async throws
        -> XRPAccountState? {
        do {
            return try await accountState(address: address)
        } catch let error as XRPProviderError where error.isAccountNotFound {
            return nil
        }
    }

    func transactionStatus(
        hash: String
    ) async throws -> SendTransactionNetworkStatus {
        let normalizedHash = hash.uppercased()
        guard SendTransactionStatusValidation.isHexHash(
            normalizedHash,
            byteCount: 32,
            allowsPrefix: false
        ) else {
            throw SendTransactionStatusProviderError
                .invalidTransactionHash(networkID: XRPConstants.networkID)
        }
        guard let transport else {
            throw XRPProviderError.missingConfiguration
        }
        let result: [String: XRPJSONValue]
        do {
            result = try await transport.request(
                method: "tx",
                parameters: [
                    "transaction": .string(normalizedHash),
                    "binary": .boolean(false)
                ]
            )
        } catch let error as XRPProviderError {
            if case let .providerRejected(code) = error,
               code == "txnnotfound" {
                return .notFound
            }
            throw error
        }
        return try Self.transactionStatus(
            from: result,
            expectedHash: normalizedHash
        )
    }

    static func transactionStatus(
        from result: [String: XRPJSONValue],
        expectedHash: String
    ) throws -> SendTransactionNetworkStatus {
        let returnedHash = result["hash"]?.stringValue
            ?? result["tx_json"]?.objectValue?["hash"]?.stringValue
        guard returnedHash?.caseInsensitiveCompare(expectedHash)
                == .orderedSame else {
            throw XRPProviderError.invalidResponse("transaction_status")
        }
        guard result["validated"]?.booleanValue == true else {
            return .pending
        }
        let metadata = result["meta"]?.objectValue
            ?? result["metaData"]?.objectValue
        guard let transactionResult = metadata?["TransactionResult"]?
                .stringValue,
              !transactionResult.isEmpty else {
            throw XRPProviderError.invalidResponse("transaction_result")
        }
        return transactionResult == "tesSUCCESS" ? .confirmed : .failed
    }

    func reserveRequirements() async throws -> XRPReserveRequirements {
        guard let transport else {
            throw XRPProviderError.missingConfiguration
        }
        let result = try await transport.request(
            method: "server_state",
            parameters: [:]
        )
        guard
            let ledger = result["state"]?.objectValue?["validated_ledger"]?
                .objectValue,
            let baseValue = ledger["reserve_base"]?.integerValue,
            let incrementValue = ledger["reserve_inc"]?.integerValue,
            baseValue > 0,
            incrementValue > 0
        else {
            throw XRPProviderError.invalidResponse("server_state_reserve")
        }
        return XRPReserveRequirements(
            baseDrops: UInt64(baseValue),
            ownerIncrementDrops: UInt64(incrementValue)
        )
    }

    func currentFeeDrops() async throws -> UInt64 {
        guard let transport else {
            throw XRPProviderError.missingConfiguration
        }
        let result = try await transport.request(
            method: "fee",
            parameters: [:]
        )
        guard let drops = result["drops"]?.objectValue,
              let openLedger = drops["open_ledger_fee"]?.stringValue,
              let value = UInt64(openLedger), value > 0
        else {
            throw XRPProviderError.invalidResponse("fee")
        }
        return value
    }

    func currentLedgerIndex() async throws -> UInt32 {
        guard let transport else {
            throw XRPProviderError.missingConfiguration
        }
        let result = try await transport.request(
            method: "ledger_current",
            parameters: [:]
        )
        guard let index = result["ledger_current_index"]?.integerValue,
              index >= 0,
              index <= Int64(UInt32.max)
        else {
            throw XRPProviderError.invalidResponse("ledger_index")
        }
        return UInt32(index)
    }

    func trustLineState(
        address: String,
        currency: String,
        issuer: String
    ) async throws -> XRPTrustLineState? {
        guard XRPAddress.validatedClassic(address) != nil,
              XRPAddress.validatedClassic(issuer) != nil,
              !currency.isEmpty,
              currency.utf8.count <= 40,
              let transport
        else {
            throw XRPProviderError.invalidAddress
        }
        var marker: XRPJSONValue?
        var seenMarkers = Set<XRPJSONValue>()
        for page in 0..<XRPConstants.maximumTrustLinePages {
            var parameters: [String: XRPJSONValue] = [
                "account": .string(address),
                "peer": .string(issuer),
                "ledger_index": .string("validated"),
                "limit": .integer(Int64(XRPConstants.trustLinePageSize))
            ]
            if let marker { parameters["marker"] = marker }
            let result: [String: XRPJSONValue]
            do {
                result = try await transport.request(
                    method: "account_lines",
                    parameters: parameters
                )
            } catch let error as XRPProviderError
                where error.isAccountNotFound {
                return nil
            }
            guard let lines = result["lines"]?.arrayValue else {
                throw XRPProviderError.invalidResponse("account_lines")
            }
            for line in lines {
                guard let object = line.objectValue,
                      let lineCurrency = object["currency"]?.stringValue,
                      let lineIssuer = object["account"]?.stringValue,
                      lineCurrency.caseInsensitiveCompare(currency)
                        == .orderedSame,
                      lineIssuer == issuer
                else {
                    continue
                }
                guard let rawBalance = object["balance"]?.stringValue,
                      let rawLimit = object["limit"]?.stringValue,
                      let rawPeerLimit = object["limit_peer"]?.stringValue,
                      let qualityIn = object["quality_in"]?.integerValue,
                      qualityIn >= 0,
                      qualityIn <= Int64(UInt32.max),
                      let qualityOut = object["quality_out"]?.integerValue,
                      qualityOut >= 0,
                      qualityOut <= Int64(UInt32.max)
                else {
                    throw XRPProviderError.invalidResponse("trust_line")
                }
                let balance = try XRPAmount.canonicalIssued(rawBalance)
                let limit = try XRPAmount.canonicalIssued(rawLimit)
                let peerLimit = try XRPAmount.canonicalIssued(rawPeerLimit)
                guard XRPAmount.isNonNegative(limit),
                      XRPAmount.isNonNegative(peerLimit)
                else {
                    throw XRPProviderError.invalidResponse("trust_line_limit")
                }
                return XRPTrustLineState(
                    balance: balance,
                    limit: limit,
                    peerLimit: peerLimit,
                    qualityIn: UInt32(qualityIn),
                    qualityOut: UInt32(qualityOut),
                    authorizedByAccount: try Self.optionalBoolean(
                        object,
                        key: "authorized"
                    ),
                    authorizedByPeer: try Self.optionalBoolean(
                        object,
                        key: "peer_authorized"
                    ),
                    frozenByAccount: try Self.optionalBoolean(
                        object,
                        key: "freeze"
                    ),
                    frozenByPeer: try Self.optionalBoolean(
                        object,
                        key: "freeze_peer"
                    ),
                    deepFrozenByAccount: try Self.optionalBoolean(
                        object,
                        key: "deep_freeze"
                    ),
                    deepFrozenByPeer: try Self.optionalBoolean(
                        object,
                        key: "deep_freeze_peer"
                    ),
                    noRippleByAccount: try Self.optionalBoolean(
                        object,
                        key: "no_ripple"
                    ),
                    noRippleByPeer: try Self.optionalBoolean(
                        object,
                        key: "no_ripple_peer"
                    )
                )
            }
            guard let next = result["marker"], next != .null else {
                return nil
            }
            guard seenMarkers.insert(next).inserted else {
                throw XRPProviderError.invalidResponse("lines_marker")
            }
            marker = next
            if page == XRPConstants.maximumTrustLinePages - 1 {
                throw XRPProviderError.invalidResponse("lines_page_limit")
            }
        }
        return nil
    }

    func depositAuthorized(
        source: String,
        destination: String
    ) async throws -> Bool {
        guard XRPAddress.validatedClassic(source) != nil,
              XRPAddress.validatedClassic(destination) != nil,
              let transport
        else {
            throw XRPProviderError.invalidAddress
        }
        let result = try await transport.request(
            method: "deposit_authorized",
            parameters: [
                "source_account": .string(source),
                "destination_account": .string(destination),
                "ledger_index": .string("validated")
            ]
        )
        guard result["source_account"]?.stringValue == source,
              result["destination_account"]?.stringValue == destination,
              let authorized = result["deposit_authorized"]?.booleanValue
        else {
            throw XRPProviderError.invalidResponse("deposit_authorized")
        }
        return authorized
    }

    private static func optionalBoolean(
        _ object: [String: XRPJSONValue],
        key: String
    ) throws -> Bool {
        guard let value = object[key] else { return false }
        guard let result = value.booleanValue else {
            throw XRPProviderError.invalidResponse("trust_line_\(key)")
        }
        return result
    }

    func submit(transactionBlob: String) async throws -> XRPSubmitResult {
        guard !transactionBlob.isEmpty, let transport else {
            throw XRPProviderError.invalidResponse("transaction_blob")
        }
        let result = try await transport.request(
            method: "submit",
            parameters: [
                "tx_blob": .string(transactionBlob),
                "fail_hard": .boolean(true)
            ]
        )
        let engine = result["engine_result"]?.stringValue
            ?? result["status"]?.stringValue
            ?? "unknown"
        let hash = result["tx_json"]?.objectValue?["hash"]?.stringValue
        return XRPSubmitResult(
            engineResult: engine,
            transactionHash: hash
        )
    }

    private func nativeBalance(
        address: String,
        transport: XRPJSONRPCTransport
    ) async throws -> XRPNativeBalanceLoad {
        let nativeDrops: String
        do {
            let info = try await transport.request(
                method: "account_info",
                parameters: [
                    "account": .string(address),
                    "ledger_index": .string("validated"),
                    "strict": .boolean(true)
                ]
            )
            guard let value = info["account_data"]?
                .objectValue?["Balance"]?.stringValue,
                  ExactDecimalText.canonicalUnsignedInteger(value) != nil
            else {
                throw XRPProviderError.invalidResponse("account_balance")
            }
            nativeDrops = value
        } catch let error as XRPProviderError {
            guard error.isAccountNotFound else { throw error }
            return XRPNativeBalanceLoad(
                balance: try Self.nativeBalance(drops: "0"),
                accountExists: false
            )
        }

        return XRPNativeBalanceLoad(
            balance: try Self.nativeBalance(drops: nativeDrops),
            accountExists: true
        )
    }

    private func trustLineBalances(
        address: String,
        transport: XRPJSONRPCTransport
    ) async throws -> XRPBalanceLoad {
        var balances: [XRPAssetBalance] = []
        var marker: XRPJSONValue?
        var seenMarkers = Set<XRPJSONValue>()
        for page in 0..<XRPConstants.maximumTrustLinePages {
            var parameters: [String: XRPJSONValue] = [
                "account": .string(address),
                "ledger_index": .string("validated"),
                "limit": .integer(Int64(XRPConstants.trustLinePageSize))
            ]
            if let marker { parameters["marker"] = marker }
            let result = try await transport.request(
                method: "account_lines",
                parameters: parameters
            )
            guard let lines = result["lines"]?.arrayValue else {
                throw XRPProviderError.invalidResponse("account_lines")
            }
            balances.append(contentsOf: try lines.compactMap(Self.lineBalance))
            guard let next = result["marker"], next != .null else {
                return XRPBalanceLoad(
                    balances: balances,
                    isComplete: true,
                    failureCodes: []
                )
            }
            guard seenMarkers.insert(next).inserted else {
                throw XRPProviderError.invalidResponse("lines_marker")
            }
            marker = next
            if page == XRPConstants.maximumTrustLinePages - 1 {
                return XRPBalanceLoad(
                    balances: balances,
                    isComplete: false,
                    failureCodes: []
                )
            }
        }
        return XRPBalanceLoad(
            balances: balances,
            isComplete: false,
            failureCodes: []
        )
    }

    private func history(
        address: String,
        transport: XRPJSONRPCTransport,
        ledgerMinimum: Int64?
    ) async throws -> XRPHistoryLoad {
        var items: [XRPHistoryItem] = []
        var marker: XRPJSONValue?
        var seenMarkers = Set<XRPJSONValue>()
        var latestValidatedLedger: Int64?
        for page in 0..<XRPConstants.maximumHistoryPages {
            var parameters: [String: XRPJSONValue] = [
                "account": .string(address),
                "ledger_index_min": .integer(ledgerMinimum ?? -1),
                "ledger_index_max": .integer(-1),
                "binary": .boolean(false),
                "forward": .boolean(false),
                "limit": .integer(Int64(XRPConstants.historyPageSize))
            ]
            if let marker { parameters["marker"] = marker }
            do {
                let result = try await transport.request(
                    method: "account_tx",
                    parameters: parameters
                )
                guard let transactions = result["transactions"]?.arrayValue
                else {
                    throw XRPProviderError.invalidResponse("account_tx")
                }
                items.append(contentsOf: try transactions.compactMap {
                    try Self.historyItem($0, owner: address)
                })
                let responseMaximum = result["ledger_index_max"]?
                    .integerValue
                let pageMaximum = items.compactMap(\.ledgerIndex).max()
                latestValidatedLedger = [
                    latestValidatedLedger,
                    responseMaximum,
                    pageMaximum
                ].compactMap { $0 }.max()
                guard let next = result["marker"], next != .null else {
                    return XRPHistoryLoad(
                        items: items,
                        isComplete: true,
                        failureCodes: [],
                        latestValidatedLedger: latestValidatedLedger
                    )
                }
                guard seenMarkers.insert(next).inserted else {
                    throw XRPProviderError.invalidResponse("tx_marker")
                }
                marker = next
            } catch let error as XRPProviderError {
                guard error.isAccountNotFound else { throw error }
                return XRPHistoryLoad(
                    items: [],
                    isComplete: true,
                    failureCodes: [],
                    latestValidatedLedger: nil
                )
            }
            if page == XRPConstants.maximumHistoryPages - 1 {
                return XRPHistoryLoad(
                    items: items,
                    isComplete: false,
                    failureCodes: [],
                    latestValidatedLedger: latestValidatedLedger
                )
            }
        }
        return XRPHistoryLoad(
            items: items,
            isComplete: false,
            failureCodes: [],
            latestValidatedLedger: latestValidatedLedger
        )
    }

    private static func nativeBalance(
        drops: String
    ) throws -> XRPAssetBalance {
        XRPAssetBalance(
            metadata: nil,
            amountText: try XRPAmount.userUnitsFromDrops(drops),
            atomicAmount: drops
        )
    }

    private static func lineBalance(
        _ value: XRPJSONValue
    ) throws -> XRPAssetBalance? {
        guard let object = value.objectValue,
              let currencyValue = object["currency"]?.stringValue,
              let issuer = object["account"]?.stringValue,
              XRPAddress.validatedClassic(issuer) != nil,
              let rawBalance = object["balance"]?.stringValue
        else {
            throw XRPProviderError.invalidResponse("trust_line")
        }
        let balance = try XRPAmount.canonicalIssued(rawBalance)
        guard XRPAmount.isPositive(balance) else { return nil }
        let currency = XRPAmount.decodedCurrency(currencyValue)
        let metadata = XRPTokenCatalog.metadata(
            currency: currency,
            issuer: issuer
        ) ?? XRPTokenMetadata(
            currency: currency,
            issuer: issuer,
            name: currency,
            symbol: currency,
            decimals: 15,
            isVerified: false,
            rank: 10_000
        )
        return XRPAssetBalance(
            metadata: metadata,
            amountText: balance,
            atomicAmount: nil
        )
    }

    private static func historyItem(
        _ value: XRPJSONValue,
        owner: String
    ) throws -> XRPHistoryItem? {
        guard let envelope = value.objectValue,
              let transaction = (
                  envelope["tx"]?.objectValue
                    ?? envelope["tx_json"]?.objectValue
              ),
              transaction["TransactionType"]?.stringValue == "Payment",
              let sender = transaction["Account"]?.stringValue,
              let recipient = transaction["Destination"]?.stringValue,
              let hash = transaction["hash"]?.stringValue
                ?? envelope["hash"]?.stringValue,
              let fee = transaction["Fee"]?.stringValue,
              ExactDecimalText.canonicalUnsignedInteger(fee) != nil
        else {
            return nil
        }
        let meta = envelope["meta"]?.objectValue
            ?? envelope["metaData"]?.objectValue
        let result = meta?["TransactionResult"]?.stringValue ?? "tesSUCCESS"
        let amount = meta?["delivered_amount"]
            ?? meta?["DeliveredAmount"]
            ?? transaction["Amount"]
        guard let amount, amount.stringValue != "unavailable" else {
            return nil
        }
        let outgoing = sender == owner
        let metadata: XRPTokenMetadata?
        let valueText: String
        if let drops = amount.stringValue,
           ExactDecimalText.canonicalUnsignedInteger(drops) != nil {
            metadata = nil
            valueText = try XRPAmount.userUnitsFromDrops(drops)
        } else if let issued = amount.objectValue,
                  let currencyValue = issued["currency"]?.stringValue,
                  let issuer = issued["issuer"]?.stringValue,
                  let issuedValue = issued["value"]?.stringValue {
            let currency = XRPAmount.decodedCurrency(currencyValue)
            metadata = XRPTokenCatalog.metadata(
                currency: currency,
                issuer: issuer
            ) ?? XRPTokenMetadata(
                currency: currency,
                issuer: issuer,
                name: currency,
                symbol: currency,
                decimals: 15,
                isVerified: false,
                rank: 10_000
            )
            valueText = XRPAmount.absolute(
                try XRPAmount.canonicalIssued(issuedValue)
            )
        } else {
            return nil
        }
        let date = transaction["date"]?.integerValue ?? 0
        return XRPHistoryItem(
            id: hash,
            transactionHash: hash,
            timestamp: TimeInterval(date) + XRPConstants.rippleEpochOffset,
            failed: result != "tesSUCCESS",
            sender: sender,
            recipient: recipient,
            destinationTag: transaction["DestinationTag"]?.integerValue
                .flatMap { $0 >= 0 ? UInt64($0) : nil },
            metadata: metadata,
            signedAmountText: XRPAmount.signed(
                valueText,
                outgoing: outgoing
            ),
            networkFeeDrops: fee,
            ledgerIndex: envelope["ledger_index"]?.integerValue
                ?? transaction["ledger_index"]?.integerValue,
            sequence: transaction["Sequence"]?.integerValue
        )
    }

    private static func failureCode(_ error: Error) -> String {
        if let error = error as? XRPProviderError {
            return error.diagnosticDescription
        }
        return "xrp_unexpected"
    }
}

struct XRPAccountState: Hashable, Sendable {
    private static let requireDestinationTagFlag: UInt32 = 0x0002_0000
    private static let requireAuthorizationFlag: UInt32 = 0x0004_0000
    private static let disallowIncomingXRPFlag: UInt32 = 0x0008_0000
    private static let disableMasterKeyFlag: UInt32 = 0x0010_0000
    private static let globalFreezeFlag: UInt32 = 0x0040_0000
    private static let depositAuthorizationFlag: UInt32 = 0x0100_0000

    let sequence: UInt32
    let balanceDrops: String
    let ownerCount: UInt32
    let flags: UInt32
    let transferRate: UInt32

    var requiresDestinationTag: Bool {
        flags & Self.requireDestinationTagFlag != 0
    }

    var requiresAuthorization: Bool {
        flags & Self.requireAuthorizationFlag != 0
    }

    var disallowsIncomingXRP: Bool {
        flags & Self.disallowIncomingXRPFlag != 0
    }

    var masterKeyIsDisabled: Bool {
        flags & Self.disableMasterKeyFlag != 0
    }

    var hasGlobalFreeze: Bool {
        flags & Self.globalFreezeFlag != 0
    }

    var requiresDepositAuthorization: Bool {
        flags & Self.depositAuthorizationFlag != 0
    }
}

struct XRPTrustLineState: Hashable, Sendable {
    let balance: String
    let limit: String
    let peerLimit: String
    let qualityIn: UInt32
    let qualityOut: UInt32
    let authorizedByAccount: Bool
    let authorizedByPeer: Bool
    let frozenByAccount: Bool
    let frozenByPeer: Bool
    let deepFrozenByAccount: Bool
    let deepFrozenByPeer: Bool
    let noRippleByAccount: Bool
    let noRippleByPeer: Bool

    var incomingQualityIsNeutral: Bool {
        qualityIn == 0 || qualityIn == 1_000_000_000
    }

    var outgoingQualityIsNeutral: Bool {
        qualityOut == 0 || qualityOut == 1_000_000_000
    }
}

struct XRPReserveRequirements: Hashable, Sendable {
    let baseDrops: UInt64
    let ownerIncrementDrops: UInt64

    func requiredDrops(ownerCount: UInt32) throws -> UInt64 {
        let (ownedReserve, multipliedOverflow) =
            ownerIncrementDrops.multipliedReportingOverflow(
                by: UInt64(ownerCount)
            )
        let (total, addedOverflow) = baseDrops
            .addingReportingOverflow(ownedReserve)
        guard !multipliedOverflow, !addedOverflow else {
            throw XRPProviderError.invalidResponse("account_reserve")
        }
        return total
    }
}

struct XRPSubmitResult: Hashable, Sendable {
    let engineResult: String
    let transactionHash: String?

    var wasAccepted: Bool {
        let normalized = engineResult.lowercased()
        return normalized.hasPrefix("tes")
            || normalized == "terqueued"
            || normalized == "tersubmitted"
            || normalized == "tefalready"
    }

    var mayHaveConsumedSequence: Bool {
        let normalized = engineResult.lowercased()
        return normalized.hasPrefix("tec")
            || normalized == "tefpast_seq"
    }
}

private struct XRPBalanceLoad: Sendable {
    let balances: [XRPAssetBalance]
    let isComplete: Bool
    let failureCodes: [String]
}

private struct XRPNativeBalanceLoad: Sendable {
    let balance: XRPAssetBalance
    let accountExists: Bool
}

private struct XRPHistoryLoad: Sendable {
    let items: [XRPHistoryItem]
    let isComplete: Bool
    let failureCodes: [String]
    let latestValidatedLedger: Int64?
}
