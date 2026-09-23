import Foundation

enum AnkrTokenAmountSource: String, Equatable, Sendable {
    case rawInteger = "raw_integer"
    case normalizedValue = "normalized_value"
}

enum AnkrTokenAmountError: Error, Equatable, Sendable {
    case missingAmount
    case missingTokenDecimals
    case invalidTokenDecimals
    case invalidRawInteger
    case rawIntegerOutOfRange
    case invalidNormalizedValue

    var diagnosticDescription: String {
        switch self {
        case .missingAmount:
            "missing_amount"
        case .missingTokenDecimals:
            "missing_token_decimals"
        case .invalidTokenDecimals:
            "invalid_token_decimals"
        case .invalidRawInteger:
            "invalid_raw_integer"
        case .rawIntegerOutOfRange:
            "raw_integer_out_of_range"
        case .invalidNormalizedValue:
            "invalid_normalized_value"
        }
    }
}

enum AnkrBalanceSnapshotError: Error, Equatable, Sendable {
    case incompletePagination
    case invalidAsset(index: Int, field: String)
    case duplicateAsset(index: Int)

    var diagnosticDescription: String {
        switch self {
        case .incompletePagination:
            "ankr_balance_snapshot_incomplete_pagination"
        case let .invalidAsset(index, field):
            "ankr_balance_snapshot_invalid_asset index=\(index) field=\(field)"
        case let .duplicateAsset(index):
            "ankr_balance_snapshot_duplicate_asset index=\(index)"
        }
    }
}

private struct AnkrMappedBalanceAsset {
    let asset: WalletAsset
    let fiatValueUnavailable: Bool
}

private struct AnkrNativeAssetMetadata {
    let name: String
    let symbol: String
    let decimals: Int
    let price: Decimal?
    let logoSource: AssetLogoSource
    let usesCatalogFallback: Bool
}

/// The exact base-10 token quantity decoded from ANKR history. Exact text is
/// authoritative; `decimalProjection` is only a bounded compatibility value
/// for existing price calculations and visibility rules.
struct AnkrTokenAmount: Equatable, Sendable {
    static let maximumUInt256 =
        "115792089237316195423570985008687907853269984665640564039457584007913129639935"

    let exactMagnitudeText: String
    let atomicText: String?
    let decimalProjection: Decimal
    let source: AnkrTokenAmountSource
    let projectionWasBounded: Bool
    let normalizedMatchesRaw: Bool?

    init(
        rawInteger: String?,
        normalizedValue: String?,
        decimals: Int?
    ) throws {
        if let rawInteger {
            guard let decimals else {
                throw AnkrTokenAmountError.missingTokenDecimals
            }
            guard (0...255).contains(decimals) else {
                throw AnkrTokenAmountError.invalidTokenDecimals
            }
            guard
                let atomic = ExactDecimalText.canonicalUnsignedInteger(
                    rawInteger
                )
            else {
                throw AnkrTokenAmountError.invalidRawInteger
            }
            guard Self.isWithinUInt256(atomic) else {
                throw AnkrTokenAmountError.rawIntegerOutOfRange
            }

            let exact = Self.userUnits(
                atomicInteger: atomic,
                decimals: decimals
            )
            let projection = Self.decimalProjection(exact)
            exactMagnitudeText = exact
            atomicText = atomic
            decimalProjection = projection.value
            source = .rawInteger
            projectionWasBounded = projection.wasBounded
            normalizedMatchesRaw = normalizedValue.flatMap(
                ExactDecimalText.canonicalUnsigned
            ).map { $0 == exact }
            return
        }

        guard let normalizedValue else {
            throw AnkrTokenAmountError.missingAmount
        }
        guard
            let exact = ExactDecimalText.canonicalUnsigned(normalizedValue)
        else {
            throw AnkrTokenAmountError.invalidNormalizedValue
        }
        let projection = Self.decimalProjection(exact)
        exactMagnitudeText = exact
        atomicText = nil
        decimalProjection = projection.value
        source = .normalizedValue
        projectionWasBounded = projection.wasBounded
        normalizedMatchesRaw = nil
    }

    private static func isWithinUInt256(_ value: String) -> Bool {
        value.count < maximumUInt256.count
            || (
                value.count == maximumUInt256.count
                    && (
                        value == maximumUInt256
                            || value.lexicographicallyPrecedes(maximumUInt256)
                    )
            )
    }

    private static func userUnits(
        atomicInteger: String,
        decimals: Int
    ) -> String {
        guard atomicInteger != "0", decimals > 0 else {
            return atomicInteger
        }

        let integer: String
        var fraction: String
        if atomicInteger.count > decimals {
            let splitIndex = atomicInteger.index(
                atomicInteger.endIndex,
                offsetBy: -decimals
            )
            integer = String(atomicInteger[..<splitIndex])
            fraction = String(atomicInteger[splitIndex...])
        } else {
            integer = "0"
            fraction = String(
                repeating: "0",
                count: decimals - atomicInteger.count
            ) + atomicInteger
        }
        while fraction.last == "0" {
            fraction.removeLast()
        }
        return fraction.isEmpty ? integer : "\(integer).\(fraction)"
    }

    private static func decimalProjection(
        _ exact: String
    ) -> (value: Decimal, wasBounded: Bool) {
        guard
            let value = Decimal(
                string: exact,
                locale: Locale(identifier: "en_US_POSIX")
            )
        else {
            return (0, true)
        }
        let projectedText = ExactDecimalText.canonicalUnsigned(
            NSDecimalNumber(decimal: value).stringValue
        )
        return (value, projectedText != exact)
    }
}

extension AnkrAPIClient {
    static func makeSnapshot(
        address: String,
        balanceResult: AnkrBalanceResult,
        transfers: [AnkrTokenTransfer],
        rawTransactions: [AnkrRawTransaction],
        historicalTokenPrices: [String: Decimal] = [:],
        authoritativeNetworkIDs: Set<String>? = nil
    ) throws -> WalletHomeSnapshot {
        let hasMorePages = balanceResult.nextPageToken.map {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        guard !hasMorePages else {
            throw AnkrBalanceSnapshotError.incompletePagination
        }

        var mappedAssets: [AnkrMappedBalanceAsset] = []
        mappedAssets.reserveCapacity(balanceResult.assets.count)
        var seenAssetIDs = Set<String>()
        do {
            for (index, providerAsset) in
                balanceResult.assets.enumerated()
            {
                let mapped = try makeAsset(
                    providerAsset,
                    index: index,
                    tokenPrice: historicalTokenPrices[assetIdentity(
                        chain: providerAsset.blockchain,
                        contract: providerAsset.contractAddress
                    )]
                )
                guard seenAssetIDs.insert(mapped.asset.id).inserted else {
                    throw AnkrBalanceSnapshotError.duplicateAsset(
                        index: index
                    )
                }
                mappedAssets.append(mapped)
            }
        } catch {
            throw error
        }
        let balanceAssets = mappedAssets.map(\.asset)
            .sorted { $0.fiatValue > $1.fiatValue }
        let unavailableFiatAssetCount = mappedAssets.filter(
            \.fiatValueUnavailable
        ).count
        let authority = EVMBalanceSnapshotAuthority(
            providerAssetCount: balanceResult.assets.count,
            mappedAssetCount: balanceAssets.count,
            unavailableFiatAssetCount: unavailableFiatAssetCount,
            hasMorePages: false,
            authoritativeNetworkIDs: authoritativeNetworkIDs
        )
        let metadata = Dictionary(
            balanceResult.assets.map { asset in
                (
                    assetIdentity(
                        chain: asset.blockchain,
                        contract: asset.contractAddress
                    ),
                    asset
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
        let rawTransactionsByIdentity = Dictionary(
            rawTransactions.map { transaction in
                (
                    transactionIdentity(
                        blockchain: transaction.blockchain,
                        hash: transaction.hash
                    ),
                    transaction
                )
            },
            uniquingKeysWith: { first, _ in first }
        )

        let transferHistory = transfers.compactMap { transfer -> AnkrTimestampedTransaction? in
            let rawTransaction = transfer.transactionHash.flatMap { hash -> AnkrRawTransaction? in
                guard let blockchain = transfer.blockchain else {
                    return nil
                }
                return rawTransactionsByIdentity[
                    transactionIdentity(
                        blockchain: blockchain,
                        hash: hash
                    )
                ]
            }
            // On a network whose native asset also has an ERC-20 facade
            // (Arc's USDC), a plain native transfer is mirrored as a facade
            // log inside the same transaction. The native transaction already
            // carries that transfer, with its fee, so the mirror is dropped.
            if let rawTransaction,
               mirrorsNativeTransfer(transfer, in: rawTransaction) {
                return nil
            }
            return makeTokenTransfer(
                transfer,
                walletAddress: address,
                metadata: metadata,
                historicalTokenPrices: historicalTokenPrices,
                rawTransaction: rawTransaction
            )
        }
        let tokenTransactionIdentities = Set(
            transfers.compactMap { transfer -> String? in
                guard
                    let blockchain = transfer.blockchain,
                    let hash = transfer.transactionHash
                else {
                    return nil
                }
                return transactionIdentity(
                    blockchain: blockchain,
                    hash: hash
                )
            }
        )
        var nativeHistory: [AnkrTimestampedTransaction] = []
        var catalogFallbackCount = 0
        var zeroValueContractCount = 0
        nativeHistory.reserveCapacity(rawTransactions.count)
        for transaction in rawTransactions {
            let identity = transactionIdentity(
                blockchain: transaction.blockchain,
                hash: transaction.hash
            )
            let representsTokenTransfer = tokenTransactionIdentities.contains(
                identity
            )
            guard let mapped = makeNativeTransaction(
                transaction,
                walletAddress: address,
                metadata: metadata,
                includesZeroValueContractCall: !representsTokenTransfer
            ) else {
                continue
            }
            nativeHistory.append(mapped)
            if nativeAssetMetadata(
                chain: transaction.blockchain,
                metadata: metadata
            )?.usesCatalogFallback == true {
                catalogFallbackCount += 1
            }
            if hexadecimalDecimal(transaction.value, decimals: 18) == 0,
               transaction.status != "0x0" {
                zeroValueContractCount += 1
            }
        }

        var seenTransactionIDs = Set<String>()
        let combinedHistory = (transferHistory + nativeHistory)
            .sorted { $0.timestamp > $1.timestamp }
            .compactMap { element -> WalletTransaction? in
                guard seenTransactionIDs.insert(
                    element.transaction.id
                ).inserted else {
                    return nil
                }
                return element.transaction
            }

        return WalletHomeSnapshot(
            totalBalance:
                balanceAssets.contains(where: \.isSpam)
                ? balanceAssets.filter { !$0.isSpam }.reduce(0) {
                    $0 + $1.fiatValue
                }
                : (
                    nonnegativeDecimal(balanceResult.totalBalanceUsd)
                        ?? balanceAssets.reduce(0) { $0 + $1.fiatValue }
                ),
            assets: balanceAssets,
            transactions: combinedHistory,
            evmBalanceAuthority: authority
        )
    }

    private static func makeAsset(
        _ asset: AnkrBalanceAsset,
        index: Int,
        tokenPrice: Decimal?
    ) throws -> AnkrMappedBalanceAsset {
        guard !asset.tokenSymbol.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw AnkrBalanceSnapshotError.invalidAsset(
                index: index,
                field: "symbol"
            )
        }
        guard WalletBlockchain(
            ankrIdentifier: asset.blockchain
        ) != nil else {
            throw AnkrBalanceSnapshotError.invalidAsset(
                index: index,
                field: "network"
            )
        }
        guard (0...255).contains(asset.tokenDecimals) else {
            throw AnkrBalanceSnapshotError.invalidAsset(
                index: index,
                field: "decimals"
            )
        }
        let isNative = asset.tokenType.caseInsensitiveCompare(
            "NATIVE"
        ) == .orderedSame
        guard
            isNative
                || AnkrAPIClient.isValidAddress(asset.contractAddress)
        else {
            throw AnkrBalanceSnapshotError.invalidAsset(
                index: index,
                field: "contract"
            )
        }
        let amount: AnkrTokenAmount
        do {
            amount = try AnkrTokenAmount(
                rawInteger: asset.balanceRawInteger,
                normalizedValue: asset.balance,
                decimals: asset.tokenDecimals
            )
        } catch {
            throw AnkrBalanceSnapshotError.invalidAsset(
                index: index,
                field: "balance"
            )
        }
        guard amount.normalizedMatchesRaw != false else {
            throw AnkrBalanceSnapshotError.invalidAsset(
                index: index,
                field: "balance_consistency"
            )
        }
        let fiatValue = isNative
            ? nonnegativeDecimal(asset.balanceUsd)
            : tokenPrice.map { amount.decimalProjection * $0 }
        let isSpam = !isNative
            && TokenSafetyPolicy.isHardDenied(
                networkID: asset.blockchain,
                contractAddress: asset.contractAddress
            )
        let mapped = WalletAsset(
            id: assetIdentity(
                chain: asset.blockchain,
                contract: asset.contractAddress
            ),
            name: asset.tokenName.isEmpty ? asset.tokenSymbol : asset.tokenName,
            symbol: asset.tokenSymbol,
            logoSource: logoSource(for: asset),
            network: WalletBlockchain(
                ankrIdentifier: asset.blockchain
            ),
            balance: amount.decimalProjection,
            fiatValue: fiatValue ?? 0,
            balanceText: amount.exactMagnitudeText,
            balanceAtomic: amount.atomicText,
            decimals: asset.tokenDecimals,
            isSpam: isSpam
        )
        return AnkrMappedBalanceAsset(
            asset: mapped,
            fiatValueUnavailable: fiatValue == nil
        )
    }

    private static func nonnegativeDecimal(_ value: String?) -> Decimal? {
        guard
            let value,
            let decimal = Decimal(
                string: value,
                locale: Locale(identifier: "en_US_POSIX")
            ),
            decimal >= 0,
            NSDecimalNumber(decimal: decimal) != .notANumber
        else {
            return nil
        }
        return decimal
    }

    static func makeTokenTransfer(
        _ transfer: AnkrTokenTransfer,
        walletAddress: String,
        metadata: [String: AnkrBalanceAsset],
        historicalTokenPrices: [String: Decimal] = [:],
        rawTransaction: AnkrRawTransaction?
    ) -> AnkrTimestampedTransaction? {
        guard
            let chain = transfer.blockchain,
            let contract = transfer.contractAddress,
            let symbol = transfer.tokenSymbol,
            !symbol.isEmpty,
            let timestamp = transfer.timestamp
        else {
            return nil
        }
        guard !TokenSafetyPolicy.isHardDenied(
            networkID: chain,
            contractAddress: contract
        ) else {
            return nil
        }

        let amount: AnkrTokenAmount
        do {
            amount = try AnkrTokenAmount(
                rawInteger: transfer.valueRawInteger,
                normalizedValue: transfer.value,
                decimals: transfer.tokenDecimals
            )
        } catch is AnkrTokenAmountError {
            return nil
        } catch {
            return nil
        }

        let isFromWallet = addressesMatch(
            transfer.fromAddress,
            walletAddress
        )
        let isToWallet = addressesMatch(
            transfer.toAddress,
            walletAddress
        )
        let isSelfTransfer = isFromWallet && isToWallet
        let isIncoming = !isSelfTransfer
            && (
                transfer.direction?.lowercased() == "in"
                    || isToWallet
            )
        let signedAmount = isIncoming
            ? magnitude(amount.decimalProjection)
            : -magnitude(amount.decimalProjection)
        guard
            let exactSignedAmount = ExactDecimalText.signedMagnitude(
                amount.exactMagnitudeText,
                isIncoming: isIncoming
            )
        else {
            return nil
        }
        let representsNativeAsset = ReceiveNetworkCatalog
            .nativeAliasContract(for: chain)
            .map { addressesMatch($0, contract) } ?? false
        let identity = representsNativeAsset
            ? assetIdentity(chain: chain, contract: zeroAddress)
            : assetIdentity(chain: chain, contract: contract)
        let balanceMetadata = metadata[identity]
        let nativeMetadata = nativeAssetMetadata(
            chain: chain,
            metadata: metadata
        )
        let tokenPrice = historicalTokenPrices[identity]
            ?? (representsNativeAsset ? nativeMetadata?.price : nil)
        let fiatValue = tokenPrice.map { signedAmount * $0 }
        guard WalletTransactionVisibilityPolicy.includesTokenTransfer(
            usdValue: fiatValue
        ) else {
            return nil
        }

        let source: AssetLogoSource
        if representsNativeAsset, let nativeMetadata {
            source = nativeMetadata.logoSource
        } else if let balanceMetadata {
            source = logoSource(for: balanceMetadata)
        } else {
            source = logoSource(
                networkID: chain,
                contractAddress: contract,
                ankrThumbnail: transfer.thumbnail
            )
        }

        let otherAddress = isIncoming
            ? transfer.fromAddress
            : transfer.toAddress
        let detailKey: String = isIncoming
            ? "wallet.activity.from"
            : "wallet.activity.to"
        let detail = EnglishNumbers.localized(
            detailKey,
            shortenedAddress(otherAddress ?? "")
        )
        let kind: WalletTransactionKind
        if isSelfTransfer {
            kind = .selfTransfer(assetSymbol: symbol)
        } else if isIncoming {
            kind = .received(assetSymbol: symbol)
        } else {
            kind = .sent(assetSymbol: symbol)
        }

        let logIndex = transfer.logIndex.map(String.init) ?? "0"
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let transaction = WalletTransaction(
            id: "\(transfer.transactionHash ?? identity)-\(contract)-\(logIndex)",
            kind: kind,
            detail: detail,
            time: EnglishNumbers.walletActivityTimestamp(date),
            assetLogoSource: source,
            assetAmount: signedAmount,
            assetAmountText: exactSignedAmount,
            assetAmountAtomic: amount.atomicText,
            assetSymbol: symbol,
            fiatValue: fiatValue,
            status: rawTransaction?.status == "0x0" ? .failed : .confirmed,
            metadata: makeTransactionMetadata(
                rawTransaction: rawTransaction,
                fallbackHash: transfer.transactionHash,
                blockchain: chain,
                date: date,
                fromAddress: transfer.fromAddress,
                toAddress: transfer.toAddress,
                fallbackBlockNumber: transfer.blockHeight,
                contractAddress: representsNativeAsset ? nil : contract,
                tokenName: transfer.tokenName,
                tokenDecimals: transfer.tokenDecimals,
                logIndex: transfer.logIndex,
                nativeMetadata: nativeMetadata
            )
        )
        return AnkrTimestampedTransaction(
            timestamp: timestamp,
            transaction: transaction
        )
    }

    static func makeNativeTransaction(
        _ raw: AnkrRawTransaction,
        walletAddress: String,
        metadata: [String: AnkrBalanceAsset],
        includesZeroValueContractCall: Bool = false
    ) -> AnkrTimestampedTransaction? {
        guard
            let timestamp = hexadecimalInt64(raw.timestamp),
            let amount = hexadecimalDecimal(raw.value, decimals: 18),
            amount != 0
                || raw.status == "0x0"
                || includesZeroValueContractCall,
            let nativeMetadata = nativeAssetMetadata(
                chain: raw.blockchain,
                metadata: metadata
            )
        else {
            return nil
        }

        let isOutgoing = addressesMatch(raw.from, walletAddress)
        let isSelfTransfer = isOutgoing
            && addressesMatch(raw.to, walletAddress)
        let signedAmount = isOutgoing ? -magnitude(amount) : magnitude(amount)
        let symbol = nativeMetadata.symbol
        let detailAddress = isOutgoing ? raw.to : raw.from
        let detail = EnglishNumbers.localized(
            isOutgoing ? "wallet.activity.to" : "wallet.activity.from",
            shortenedAddress(detailAddress ?? "")
        )
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let transaction = WalletTransaction(
            id: "\(raw.hash)-native",
            kind: isSelfTransfer
                ? .selfTransfer(assetSymbol: symbol)
                : isOutgoing
                    ? .sent(assetSymbol: symbol)
                    : .received(assetSymbol: symbol),
            detail: detail,
            time: EnglishNumbers.walletActivityTimestamp(date),
            assetLogoSource: nativeMetadata.logoSource,
            assetAmount: signedAmount,
            assetSymbol: symbol,
            fiatValue: nativeMetadata.price.map { signedAmount * $0 },
            status: raw.status == "0x0" ? .failed : .confirmed,
            metadata: makeTransactionMetadata(
                rawTransaction: raw,
                fallbackHash: raw.hash,
                blockchain: raw.blockchain,
                date: date,
                fromAddress: raw.from,
                toAddress: raw.to,
                fallbackBlockNumber: nil,
                contractAddress: nil,
                tokenName: nativeMetadata.name,
                tokenDecimals: nativeMetadata.decimals,
                logIndex: nil,
                nativeMetadata: nativeMetadata
            )
        )
        return AnkrTimestampedTransaction(
            timestamp: timestamp,
            transaction: transaction
        )
    }

    private static func nativeAssetMetadata(
        chain: String,
        metadata: [String: AnkrBalanceAsset]
    ) -> AnkrNativeAssetMetadata? {
        let balanceMetadata = metadata[
            assetIdentity(chain: chain, contract: zeroAddress)
        ] ?? metadata.values.first {
            $0.blockchain == chain
                && $0.tokenType.caseInsensitiveCompare("NATIVE")
                    == .orderedSame
        }
        if let balanceMetadata {
            return AnkrNativeAssetMetadata(
                name: balanceMetadata.tokenName.isEmpty
                    ? balanceMetadata.tokenSymbol
                    : balanceMetadata.tokenName,
                symbol: balanceMetadata.tokenSymbol,
                decimals: balanceMetadata.tokenDecimals,
                price: decimalIfPresent(balanceMetadata.tokenPrice),
                logoSource: logoSource(for: balanceMetadata),
                usesCatalogFallback: false
            )
        }
        guard let network = ReceiveNetworkCatalog.network(for: chain) else {
            return nil
        }
        let nativeAsset = ReceiveToken.nativeAsset(for: network)
        return AnkrNativeAssetMetadata(
            name: nativeAsset.name,
            symbol: nativeAsset.symbol,
            decimals: nativeAsset.variants.first?.decimals ?? 18,
            price: nil,
            logoSource: .nativeCoin(blockchain: network.blockchain),
            usesCatalogFallback: true
        )
    }

    static func logoSource(
        for asset: AnkrBalanceAsset
    ) -> AssetLogoSource {
        if asset.tokenType.uppercased() == "NATIVE" {
            guard
                let blockchain = WalletBlockchain(
                    ankrIdentifier: asset.blockchain
                )
            else {
                return .unavailable
            }
            return .nativeCoin(blockchain: blockchain)
        }

        return logoSource(
            networkID: asset.blockchain,
            contractAddress: asset.contractAddress,
            ankrThumbnail: asset.thumbnail
        )
    }

    static func logoSource(
        networkID: String,
        contractAddress: String,
        ankrThumbnail: String?
    ) -> AssetLogoSource {
        if let catalogSource = ReceiveAssetCatalog.variant(
            networkID: networkID,
            contractAddress: contractAddress
        )?.logoSource, catalogSource.remoteLogoURL != nil {
            return catalogSource
        }
        guard let blockchain = WalletBlockchain(
            ankrIdentifier: networkID
        ) else {
            return .unavailable
        }
        return .ankrToken(
            blockchain: blockchain,
            contractAddress: contractAddress,
            logoURL: ankrThumbnail
        )
    }

    static func decimal(_ string: String) -> Decimal {
        Decimal(
            string: string,
            locale: Locale(identifier: "en_US_POSIX")
        ) ?? 0
    }

    static func decimalIfPresent(_ string: String?) -> Decimal? {
        guard let string else { return nil }
        return Decimal(
            string: string,
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func magnitude(_ value: Decimal) -> Decimal {
        value < 0 ? -value : value
    }

    static func shortenedAddress(_ address: String) -> String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }

    /// True when `transfer` is the ERC-20 facade's echo of the native value
    /// carried by `transaction`: same transaction, same parties, and the
    /// facade amount is the native amount truncated to the facade's decimals.
    static func mirrorsNativeTransfer(
        _ transfer: AnkrTokenTransfer,
        in transaction: AnkrRawTransaction
    ) -> Bool {
        guard
            let blockchain = transfer.blockchain,
            let alias = ReceiveNetworkCatalog.nativeAliasContract(for: blockchain),
            let contract = transfer.contractAddress,
            addressesMatch(alias, contract),
            let to = transaction.to,
            addressesMatch(transfer.fromAddress, transaction.from),
            addressesMatch(transfer.toAddress, to),
            let nativeAmount = hexadecimalDecimal(transaction.value, decimals: 18),
            nativeAmount > 0
        else {
            return false
        }
        guard
            let facadeDecimals = transfer.tokenDecimals,
            let rawFacadeAmount = transfer.valueRawInteger,
            let facadeUnits = Decimal(string: rawFacadeAmount)
        else {
            // Without an exact facade amount the shared parties and value
            // are evidence enough.
            return true
        }
        var scaled = nativeAmount
        for _ in 0..<facadeDecimals {
            scaled *= 10
        }
        var truncated = Decimal.zero
        NSDecimalRound(&truncated, &scaled, 0, .down)
        return truncated == facadeUnits
    }

    static func addressesMatch(
        _ candidate: String?,
        _ walletAddress: String
    ) -> Bool {
        guard let candidate else { return false }
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(
                walletAddress.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            ) == .orderedSame
    }

    static func assetIdentity(chain: String, contract: String) -> String {
        "\(chain.lowercased()):\(contract.lowercased())"
    }

    static func transactionIdentity(
        blockchain: String,
        hash: String
    ) -> String {
        "\(blockchain.lowercased()):\(hash.lowercased())"
    }

    private static func makeTransactionMetadata(
        rawTransaction: AnkrRawTransaction?,
        fallbackHash: String?,
        blockchain: String,
        date: Date,
        fromAddress: String?,
        toAddress: String?,
        fallbackBlockNumber: Int64?,
        contractAddress: String?,
        tokenName: String?,
        tokenDecimals: Int?,
        logIndex: Int?,
        nativeMetadata: AnkrNativeAssetMetadata?
    ) -> WalletTransactionMetadata {
        let gasPriceWei = rawTransaction?.gasPrice.flatMap(hexadecimalDecimal)
        let gasUsed = rawTransaction?.gasUsed.flatMap(hexadecimalInt64)
        let networkFee = gasPriceWei.flatMap { gasPrice in
            gasUsed.map { used in
                scaleWei(gasPrice * Decimal(used))
            }
        }
        let nativePrice = nativeMetadata?.price

        return WalletTransactionMetadata(
            transactionHash: rawTransaction?.hash ?? fallbackHash,
            blockchainIdentifier: blockchain,
            date: date,
            // Token-transfer events describe the actual asset sender and
            // recipient. The raw EVM transaction's `to` value is the token
            // contract being called, so it must only be a fallback for native
            // transactions that do not provide event-level addresses.
            fromAddress: fromAddress ?? rawTransaction?.from,
            toAddress: toAddress ?? rawTransaction?.to,
            blockNumber: rawTransaction?.blockNumber.flatMap(hexadecimalInt64)
                ?? fallbackBlockNumber,
            blockHash: rawTransaction?.blockHash,
            contractAddress: contractAddress,
            tokenName: tokenName,
            tokenDecimals: tokenDecimals,
            logIndex: logIndex,
            networkFee: networkFee,
            networkFeeFiatValue: networkFee.flatMap { fee in
                nativePrice.map { fee * $0 }
            },
            networkFeeSymbol: nativeMetadata?.symbol,
            gasPriceGwei: gasPriceWei.map { scaleGwei($0) },
            gasLimit: rawTransaction?.gas.flatMap(hexadecimalInt64),
            gasUsed: gasUsed,
            nonce: rawTransaction?.nonce.flatMap(hexadecimalInt64),
            transactionIndex: rawTransaction?.transactionIndex
                .flatMap(hexadecimalInt64),
            transactionType: rawTransaction?.type.flatMap(hexadecimalInt64),
            inputData: rawTransaction?.input,
            note: nil
        )
    }

    static func hexadecimalInt64(_ value: String) -> Int64? {
        let digits = value.lowercased().hasPrefix("0x")
            ? String(value.dropFirst(2))
            : value
        return Int64(digits, radix: 16)
    }

    static func hexadecimalDecimal(
        _ value: String,
        decimals: Int
    ) -> Decimal? {
        let digits = value.lowercased().hasPrefix("0x")
            ? value.dropFirst(2)
            : value[...]
        guard !digits.isEmpty else { return 0 }

        var result = Decimal.zero
        for character in digits {
            guard let digit = character.hexDigitValue else { return nil }
            result *= 16
            result += Decimal(digit)
        }
        for _ in 0..<decimals {
            result /= 10
        }
        return result
    }

    static func hexadecimalDecimal(_ value: String) -> Decimal? {
        hexadecimalDecimal(value, decimals: 0)
    }

    static func scaleWei(_ value: Decimal) -> Decimal {
        var result = value
        for _ in 0..<18 {
            result /= 10
        }
        return result
    }

    static func scaleGwei(_ value: Decimal) -> Decimal {
        var result = value
        for _ in 0..<9 {
            result /= 10
        }
        return result
    }

    static var zeroAddress: String {
        "0x0000000000000000000000000000000000000000"
    }
}
