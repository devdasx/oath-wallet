import Foundation

/// Canonical base-10 text used when a blockchain quantity exceeds
/// `Foundation.Decimal`. The exact text remains authoritative; numeric models
/// may keep a bounded `Decimal` projection for sorting and fiat calculations.
enum ExactDecimalText {
    private static let maximumCharacterCount = 512

    static func canonicalUnsigned(_ value: String) -> String? {
        canonical(value, permitsSign: false)
    }

    static func canonicalUnsignedInteger(_ value: String) -> String? {
        guard
            !value.isEmpty,
            value.count <= maximumCharacterCount,
            value.utf8.allSatisfy(isASCIIDigit)
        else {
            return nil
        }
        let significant = value.drop(while: { $0 == "0" })
        return significant.isEmpty ? "0" : String(significant)
    }

    static func canonicalMagnitude(_ value: String) -> String? {
        canonical(value, permitsSign: true).map {
            $0.first == "-" ? String($0.dropFirst()) : $0
        }
    }

    static func signedMagnitude(
        _ value: String,
        isIncoming: Bool
    ) -> String? {
        guard let magnitude = canonicalMagnitude(value) else {
            return nil
        }
        guard magnitude != "0", !isIncoming else {
            return magnitude
        }
        return "-\(magnitude)"
    }

    static func isNonzeroUnsigned(_ value: String) -> Bool {
        canonicalUnsigned(value).map { $0 != "0" } == true
    }

    static func rounded(
        _ value: String,
        maximumFractionDigits: Int
    ) -> String? {
        guard
            maximumFractionDigits >= 0,
            let canonical = canonical(value, permitsSign: true)
        else {
            return nil
        }

        let isNegative = canonical.hasPrefix("-")
        let magnitude = isNegative
            ? String(canonical.dropFirst())
            : canonical
        let components = magnitude.split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let integer = String(components[0])
        let fraction = components.count == 2
            ? String(components[1])
            : ""
        guard fraction.count > maximumFractionDigits else {
            return canonical
        }

        let retainedFraction = String(
            fraction.prefix(maximumFractionDigits)
        )
        var retainedDigits = Array(
            (integer + retainedFraction).utf8
        )
        let roundingDigit = fraction.utf8
            .dropFirst(maximumFractionDigits)
            .first
        if roundingDigit.map({ $0 >= 53 }) == true {
            retainedDigits = increment(retainedDigits)
        }

        let integerDigitCount =
            retainedDigits.count - maximumFractionDigits
        let roundedInteger = String(
            decoding: retainedDigits[..<integerDigitCount],
            as: UTF8.self
        )
        var roundedFraction = Array(
            retainedDigits[integerDigitCount...]
        )
        while roundedFraction.last == 48 {
            roundedFraction.removeLast()
        }

        let roundedMagnitude = roundedFraction.isEmpty
            ? roundedInteger
            : roundedInteger
                + "."
                + String(decoding: roundedFraction, as: UTF8.self)
        guard roundedMagnitude != "0", isNegative else {
            return roundedMagnitude
        }
        return "-\(roundedMagnitude)"
    }

    private static func canonical(
        _ value: String,
        permitsSign: Bool
    ) -> String? {
        guard
            !value.isEmpty,
            value.count <= maximumCharacterCount,
            value.utf8.allSatisfy({ $0 < 128 })
        else {
            return nil
        }

        var body = value[...]
        var isNegative = false
        if body.first == "-" || body.first == "+" {
            guard permitsSign else { return nil }
            isNegative = body.first == "-"
            body = body.dropFirst()
        }
        guard !body.isEmpty else { return nil }

        let pieces = body.split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard pieces.count <= 2 else { return nil }
        let integerBytes = pieces[0].utf8
        let fractionBytes = pieces.count == 2 ? pieces[1].utf8 : nil
        guard
            (!integerBytes.isEmpty || fractionBytes?.isEmpty == false),
            integerBytes.allSatisfy(Self.isASCIIDigit),
            fractionBytes?.allSatisfy(Self.isASCIIDigit) != false
        else {
            return nil
        }

        let integer = String(pieces[0])
            .drop(while: { $0 == "0" })
        var fraction = pieces.count == 2 ? String(pieces[1]) : ""
        while fraction.last == "0" {
            fraction.removeLast()
        }
        let canonicalInteger = integer.isEmpty ? "0" : String(integer)
        let magnitude = fraction.isEmpty
            ? canonicalInteger
            : "\(canonicalInteger).\(fraction)"
        guard magnitude != "0", isNegative else {
            return magnitude
        }
        return "-\(magnitude)"
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
    }

    private static func increment(_ digits: [UInt8]) -> [UInt8] {
        var result = digits
        var index = result.count
        while index > 0 {
            index -= 1
            if result[index] < 57 {
                result[index] += 1
                return result
            }
            result[index] = 48
        }
        result.insert(49, at: 0)
        return result
    }
}

enum WalletHomeLoadState: Equatable {
    case loading
    case content(WalletHomeSnapshot)
    case failed

    /// The home screen never replaces persisted wallet values with fabricated
    /// loading bars. Before the first snapshot exists, it presents the real
    /// empty wallet state while synchronization runs in the background.
    var displayedSnapshot: WalletHomeSnapshot? {
        switch self {
        case .loading:
            .empty
        case let .content(snapshot):
            snapshot
        case .failed:
            nil
        }
    }
}

struct EVMBalanceSnapshotAuthority: Equatable, Sendable {
    let providerAssetCount: Int
    let mappedAssetCount: Int
    let unavailableFiatAssetCount: Int
    let hasMorePages: Bool
    /// Networks whose balance inventories completed successfully. A nil value
    /// is retained only for legacy/test snapshots created without network-level
    /// provenance; production ANKR snapshots always provide this set.
    let authoritativeNetworkIDs: Set<String>?

    init(
        providerAssetCount: Int,
        mappedAssetCount: Int,
        unavailableFiatAssetCount: Int,
        hasMorePages: Bool,
        authoritativeNetworkIDs: Set<String>? = nil
    ) {
        self.providerAssetCount = providerAssetCount
        self.mappedAssetCount = mappedAssetCount
        self.unavailableFiatAssetCount = unavailableFiatAssetCount
        self.hasMorePages = hasMorePages
        self.authoritativeNetworkIDs = authoritativeNetworkIDs
    }

    var isAuthoritative: Bool {
        !hasMorePages
            && providerAssetCount == mappedAssetCount
    }
}

struct WalletHomeSnapshot: Equatable, Sendable {
    let totalBalance: Decimal
    let assets: [WalletAsset]
    let transactions: [WalletTransaction]
    let persistenceTransactions: [WalletTransaction]
    let hasStoredActivity: Bool
    let evmBalanceAuthority: EVMBalanceSnapshotAuthority?

    init(
        totalBalance: Decimal,
        assets: [WalletAsset],
        transactions: [WalletTransaction],
        hasStoredActivity: Bool? = nil,
        evmBalanceAuthority: EVMBalanceSnapshotAuthority? = nil
    ) {
        self.totalBalance = totalBalance
        self.assets = assets
        self.persistenceTransactions = transactions
        self.hasStoredActivity =
            hasStoredActivity ?? !transactions.isEmpty
        self.transactions = transactions.filter(
            WalletTransactionVisibilityPolicy.includes
        )
        self.evmBalanceAuthority = evmBalanceAuthority
    }

    func replacingPortfolio(
        _ portfolio: WalletHomePortfolioSnapshotSlice
    ) -> WalletHomeSnapshot {
        WalletHomeSnapshot(
            totalBalance: portfolio.totalBalance,
            assets: portfolio.assets,
            transactions: persistenceTransactions,
            hasStoredActivity: hasStoredActivity,
            evmBalanceAuthority: evmBalanceAuthority
        )
    }

    func replacingActivity(
        _ activity: WalletHomeActivitySnapshotSlice
    ) -> WalletHomeSnapshot {
        WalletHomeSnapshot(
            totalBalance: totalBalance,
            assets: assets,
            transactions: activity.transactions,
            hasStoredActivity: activity.hasStoredActivity,
            evmBalanceAuthority: evmBalanceAuthority
        )
    }

    static let sample = WalletHomeSnapshot(
        totalBalance: decimal("24680.47"),
        assets: [
            WalletAsset(
                id: "ethereum",
                name: WalletLocalization.string("wallet.asset.ethereum.name"),
                symbol: "ETH",
                logoSource: .nativeCoin(blockchain: .ethereum),
                network: .ethereum,
                balance: decimal("3.4821"),
                fiatValue: decimal("10892.26")
            ),
            WalletAsset(
                id: "usd-coin",
                name: WalletLocalization.string("wallet.asset.usdc.name"),
                symbol: "USDC",
                logoSource: .catalogToken(
                    blockchain: .ethereum,
                    contractAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
                    logoURL: nil
                ),
                network: .ethereum,
                balance: decimal("8450"),
                fiatValue: decimal("8450")
            ),
            WalletAsset(
                id: "chainlink",
                name: WalletLocalization.string("wallet.asset.chainlink.name"),
                symbol: "LINK",
                logoSource: .catalogToken(
                    blockchain: .ethereum,
                    contractAddress: "0x514910771AF9Ca656af840dff83E8264EcF986CA",
                    logoURL: nil
                ),
                network: .ethereum,
                balance: decimal("342.18"),
                fiatValue: decimal("5338.21")
            )
        ],
        transactions: [
            WalletTransaction(
                id: "received-eth",
                kind: .received(assetSymbol: "ETH"),
                detail: EnglishNumbers.localized(
                    "wallet.activity.from",
                    "0x93C2…4A18"
                ),
                time: WalletLocalization.string(
                    "wallet.activity.day.today"
                ),
                assetLogoSource: .nativeCoin(blockchain: .ethereum),
                assetAmount: decimal("0.85"),
                assetSymbol: "ETH",
                fiatValue: decimal("2657.39"),
                status: .confirmed
            ),
            WalletTransaction(
                id: "sent-usdc",
                kind: .sent(assetSymbol: "USDC"),
                detail: EnglishNumbers.localized(
                    "wallet.activity.to",
                    "0x61D0…7E30"
                ),
                time: WalletLocalization.string(
                    "wallet.activity.day.yesterday"
                ),
                assetLogoSource: .catalogToken(
                    blockchain: .ethereum,
                    contractAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
                    logoURL: nil
                ),
                assetAmount: decimal("-420"),
                assetSymbol: "USDC",
                fiatValue: decimal("-420"),
                status: .confirmed
            ),
            WalletTransaction(
                id: "swapped-eth-link",
                kind: .swapped(
                    sourceSymbol: "ETH",
                    destinationSymbol: "LINK"
                ),
                detail: EnglishNumbers.localized(
                    "wallet.activity.via",
                    "Uniswap"
                ),
                time: WalletLocalization.string(
                    "wallet.activity.day.yesterday"
                ),
                assetLogoSource: .nativeCoin(blockchain: .ethereum),
                assetAmount: decimal("-0.40"),
                assetSymbol: "ETH",
                fiatValue: decimal("-1251.48"),
                status: .confirmed
            )
        ]
    )

    static let empty = WalletHomeSnapshot(
        totalBalance: 0,
        assets: [],
        transactions: []
    )

    private static func decimal(_ value: String) -> Decimal {
        Decimal(
            string: value,
            locale: Locale(identifier: "en_US_POSIX")
        ) ?? 0
    }
}

struct WalletAsset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let logoSource: AssetLogoSource
    let network: WalletBlockchain?
    let balance: Decimal
    let fiatValue: Decimal
    let balanceText: String?
    let balanceAtomic: String?
    let decimals: Int?
    let receiveAddress: String?
    let isPinned: Bool
    let isVerified: Bool
    let isSpam: Bool

    init(
        id: String,
        name: String,
        symbol: String,
        logoSource: AssetLogoSource,
        network: WalletBlockchain?,
        balance: Decimal,
        fiatValue: Decimal,
        balanceText: String? = nil,
        balanceAtomic: String? = nil,
        decimals: Int? = nil,
        receiveAddress: String? = nil,
        isPinned: Bool = false,
        isVerified: Bool = true,
        isSpam: Bool = false
    ) {
        self.id = id
        self.name = logoSource.localizedNativeAssetName ?? name
        self.symbol = symbol
        self.logoSource = logoSource
        self.network = network
        self.balance = balance
        self.fiatValue = fiatValue
        self.balanceText = balanceText
        self.balanceAtomic = balanceAtomic
        self.decimals = decimals
        self.receiveAddress = receiveAddress
        self.isPinned = isPinned
        self.isVerified = isVerified
        self.isSpam = isSpam
    }

    var requiresExplicitVisibility: Bool {
        guard network == .solana || network == .sui || network == .near
                || network == .stellar else {
            return false
        }
        if case .nativeCoin = logoSource {
            return false
        }
        return !isVerified || isSpam
    }

    var networkLogoSource: AssetLogoSource {
        guard let network else { return .unavailable }
        return .network(blockchain: network)
    }

    /// The curated family this asset belongs to, per the installed catalog.
    var family: AssetFamily? {
        ReceiveAssetCatalog.family(forAssetIdentity: id)
    }

    var familyLogoSource: AssetLogoSource? {
        family?.logoSource
    }

    var displayBalanceText: String {
        balanceText.flatMap(ExactDecimalText.canonicalUnsigned)
            ?? EnglishNumbers.decimal(balance)
    }
}

enum WalletBlockchain: String, Hashable, Sendable {
    case aptos
    case stellar
    case near
    case xrp
    case sui
    case ton
    case tron
    case solana
    case bitcoin
    case bitcoincash
    case litecoin
    case dogecoin = "doge"
    case ethereum
    case smartchain
    case polygon
    case arbitrum
    case avalanchec
    case optimism
    case base
    case xdai
    case scroll
    case linea
    case taiko
    case telos
    case xlayer
    case arc

    init?(ankrIdentifier: String) {
        switch ankrIdentifier {
        case "eth": self = .ethereum
        case "bsc": self = .smartchain
        case "polygon": self = .polygon
        case "arbitrum": self = .arbitrum
        case "avalanche": self = .avalanchec
        case "optimism": self = .optimism
        case "base": self = .base
        case "gnosis": self = .xdai
        case "scroll": self = .scroll
        case "linea": self = .linea
        case "taiko": self = .taiko
        case "telos": self = .telos
        case "xlayer": self = .xlayer
        case "arc": self = .arc
        default: return nil
        }
    }

    /// Only these chains share the app's EVM account identity. Keeping this
    /// as a positive allowlist prevents a newly added non-EVM network from
    /// accidentally inheriting an Ethereum address.
    var isEVM: Bool {
        switch self {
        case .ethereum,
             .smartchain,
             .polygon,
             .arbitrum,
             .avalanchec,
             .optimism,
             .base,
             .xdai,
             .scroll,
             .linea,
             .taiko,
             .telos,
             .xlayer,
             .arc:
            true
        case .aptos,
             .stellar,
             .near,
             .xrp,
             .sui,
             .ton,
             .tron,
             .solana,
             .bitcoin,
             .bitcoincash,
             .litecoin,
             .dogecoin:
            false
        }
    }

    var officialLogoAssetName: String {
        switch self {
        case .aptos: "NetworkLogoAptos"
        case .stellar: "NetworkLogoStellar"
        case .near: "NetworkLogoNEAR"
        case .xrp: "NetworkLogoXRP"
        case .sui: "NetworkLogoSui"
        case .ton: "NetworkLogoTON"
        case .bitcoin: "NetworkLogoBitcoin"
        case .bitcoincash: "NetworkLogoBitcoinCash"
        case .litecoin: "NetworkLogoLitecoin"
        case .dogecoin: "NetworkLogoDogecoin"
        case .ethereum: "NetworkLogoEthereum"
        case .tron: "NetworkLogoTron"
        case .solana: "NetworkLogoSolana"
        case .smartchain: "NetworkLogoBNBSmartChain"
        case .arbitrum: "NetworkLogoArbitrum"
        case .base: "NetworkLogoBase"
        case .polygon: "NetworkLogoPolygon"
        case .optimism: "NetworkLogoOptimism"
        case .avalanchec: "NetworkLogoAvalanche"
        case .xdai: "NetworkLogoGnosis"
        case .linea: "NetworkLogoLinea"
        case .scroll: "NetworkLogoScroll"
        case .taiko: "NetworkLogoTaiko"
        case .telos: "NetworkLogoTelos"
        case .xlayer: "NetworkLogoXLayer"
        case .arc: "NetworkLogoArc"
        }
    }
}

enum AssetLogoSourceOrigin: String, Hashable, Sendable {
    case bundled
    case catalog
    case ankr
}

enum AssetLogoSource: Hashable, Sendable {
    case nativeCoin(blockchain: WalletBlockchain)
    case network(blockchain: WalletBlockchain)
    case token(
        blockchain: WalletBlockchain,
        checksummedContractAddress: String,
        logoURL: URL?,
        origin: AssetLogoSourceOrigin
    )
    /// The badge of an asset family (bStocks…), drawn beside the network badge.
    case family(AssetFamily)
    case unavailable

    var blockchain: WalletBlockchain? {
        switch self {
        case let .nativeCoin(blockchain),
             let .network(blockchain),
             let .token(blockchain, _, _, _):
            blockchain
        case let .family(family):
            family.blockchain
        case .unavailable:
            nil
        }
    }

    var checksummedContractAddress: String? {
        guard case let .token(
            _,
            checksummedContractAddress,
            _,
            _
        ) = self else {
            return nil
        }
        return checksummedContractAddress
    }

    var origin: AssetLogoSourceOrigin? {
        switch self {
        case .nativeCoin, .network, .family:
            .bundled
        case let .token(_, _, _, origin):
            origin
        case .unavailable:
            nil
        }
    }

    var bundledAssetName: String? {
        switch self {
        case .nativeCoin(.ton):
            return "NativeCoinGram"
        case .nativeCoin(.arc):
            // Arc's gas token is USDC itself, so the balance row shows the
            // stablecoin, not the chain mark.
            return "NativeCoinUSDC"
        case let .nativeCoin(blockchain),
             let .network(blockchain):
            return blockchain.officialLogoAssetName
        case let .family(family):
            return family.logoAssetName
        case .token, .unavailable:
            return nil
        }
    }

    var remoteLogoURL: URL? {
        guard case let .token(_, _, logoURL, _) = self else {
            return nil
        }
        return logoURL
    }

    var logoURLs: [URL] {
        remoteLogoURL.map { [$0] } ?? []
    }

    var diagnosticIdentity: String {
        switch self {
        case let .nativeCoin(blockchain):
            return "\(blockchain.rawValue):native:bundled"
        case let .network(blockchain):
            return "\(blockchain.rawValue):network:bundled"
        case let .family(family):
            return "family:\(family.rawValue):bundled"
        case let .token(
            blockchain,
            checksummedContractAddress,
            _,
            origin
        ):
            return "\(blockchain.rawValue):\(checksummedContractAddress):\(origin.rawValue)"
        case .unavailable:
            return "unavailable"
        }
    }

    /// Fill missing artwork from an exact catalog identity. Existing images
    /// remain usable when a catalog entry has no artwork yet.
    func resolvingCatalogArtwork(assetIdentity: String? = nil) -> AssetLogoSource {
        guard bundledAssetName == nil, remoteLogoURL == nil else { return self }
        let identity: String?
        if let assetIdentity {
            identity = assetIdentity
        } else if let blockchain, let contract = checksummedContractAddress,
                  let networkID = AssetNetworkSelectorOption.networkID(for: blockchain) {
            identity = AssetIdentityKey.make(networkID: networkID, contractAddress: contract)
        } else {
            identity = nil
        }
        guard let identity,
              let selection = ReceiveAssetCatalog.selection(assetIdentity: identity),
              selection.variant.logoSource.remoteLogoURL != nil else { return self }
        return selection.variant.logoSource
    }

    static func catalogToken(
        blockchain: WalletBlockchain,
        contractAddress: String,
        logoURL: String?
    ) -> AssetLogoSource {
        return .token(
            blockchain: blockchain,
            checksummedContractAddress: contractAddress,
            logoURL: validatedCatalogLogoURL(logoURL),
            origin: .catalog
        )
    }

    static func ankrToken(
        blockchain: WalletBlockchain,
        contractAddress: String,
        logoURL: String?
    ) -> AssetLogoSource {
        .token(
            blockchain: blockchain,
            checksummedContractAddress: contractAddress,
            logoURL: validatedRemoteLogoURL(logoURL),
            origin: .ankr
        )
    }

    private static func validatedRemoteLogoURL(_ value: String?) -> URL? {
        guard
            let value = value?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !value.isEmpty,
            let url = URL(string: value),
            url.scheme?.lowercased() == "https",
            url.host?.isEmpty == false
        else {
            return nil
        }
        return url
    }

    private static func validatedCatalogLogoURL(_ value: String?) -> URL? {
        guard let value,
              AssetCatalogEntryValidation.isValidCatalogLogoURL(value) else { return nil }
        return URL(string: value)
    }

}

struct WalletTransaction: Identifiable, Hashable, Sendable {
    static let maximumDisplayedFractionDigits = 8

    let id: String
    let kind: WalletTransactionKind
    let detail: String
    let time: String
    let assetLogoSource: AssetLogoSource
    let assetAmount: Decimal
    let assetAmountText: String?
    let assetAmountAtomic: String?
    let assetSymbol: String
    let fiatValue: Decimal?
    let status: WalletTransactionStatus
    let metadata: WalletTransactionMetadata
    let replacementTransactionHash: String?

    init(
        id: String,
        kind: WalletTransactionKind,
        detail: String,
        time: String,
        assetLogoSource: AssetLogoSource,
        assetAmount: Decimal,
        assetAmountText: String? = nil,
        assetAmountAtomic: String? = nil,
        assetSymbol: String,
        fiatValue: Decimal?,
        status: WalletTransactionStatus,
        metadata: WalletTransactionMetadata = .empty,
        replacementTransactionHash: String? = nil
    ) {
        self.id = id
        self.kind = kind.resolvingSelfTransfer(metadata: metadata)
        self.detail = detail
        self.time = time
        self.assetLogoSource = assetLogoSource
        self.assetAmount = assetAmount
        self.assetAmountText = assetAmountText.flatMap {
            ExactDecimalText.signedMagnitude(
                $0,
                isIncoming: !$0.hasPrefix("-")
            )
        }
        self.assetAmountAtomic = assetAmountAtomic.flatMap(
            ExactDecimalText.canonicalUnsignedInteger
        )
        self.assetSymbol = assetSymbol
        self.fiatValue = fiatValue
        self.status = status
        self.metadata = metadata
        self.replacementTransactionHash = replacementTransactionHash
    }

    var historyDetail: String? {
        switch kind {
        case .received, .selfTransfer:
            nil
        case .sent, .swapped:
            detail
        }
    }

    /// An unsuccessful outcome takes precedence over the attempted direction.
    /// Otherwise a replaced incoming payment would still read as "Received".
    var activityTitle: String {
        switch status {
        case .pending, .confirmed:
            kind.localizedTitle
        case .canceled, .failed, .notFound, .replaced:
            WalletLocalization.string(status.localizedKey)
        }
    }

    var activitySubtitle: String {
        switch status {
        case .pending:
            WalletLocalization.string(status.localizedKey)
        case .confirmed:
            metadata.date.map { EnglishNumbers.walletActivityTimestamp($0) }
                ?? WalletLocalization.string(status.localizedKey)
        case .canceled, .failed, .notFound, .replaced:
            // Stored displayTime can contain an old, localized "Pending".
            // Only a real timestamp may accompany a terminal/unknown outcome.
            metadata.date.map { EnglishNumbers.walletActivityTimestamp($0) } ?? ""
        }
    }

    var isTokenTransfer: Bool {
        if metadata.contractAddress != nil {
            return true
        }

        if case .token = assetLogoSource {
            return true
        }

        return false
    }

    var displayAssetAmountText: String {
        guard
            let assetAmountText,
            let roundedText = ExactDecimalText.rounded(
                assetAmountText,
                maximumFractionDigits:
                    Self.maximumDisplayedFractionDigits
            )
        else {
            return EnglishNumbers.decimal(
                assetAmount,
                maximumFractionDigits:
                    Self.maximumDisplayedFractionDigits,
                includesPositiveSign: assetAmount > 0
            )
        }
        guard roundedText != "0",
              !roundedText.hasPrefix("-") else {
            return roundedText
        }
        return "+\(roundedText)"
    }
}

enum WalletTransactionVisibilityPolicy {
    static let minimumTokenUSDValue = Decimal(
        string: "0.10",
        locale: Locale(identifier: "en_US_POSIX")
    ) ?? Decimal(1) / 10

    static func includes(_ transaction: WalletTransaction) -> Bool {
        guard transaction.isTokenTransfer else { return true }
        return includesTokenTransfer(usdValue: transaction.fiatValue)
    }

    static func includesTokenTransfer(usdValue: Decimal?) -> Bool {
        guard let usdValue else { return false }
        let absoluteUSDValue = usdValue < 0 ? -usdValue : usdValue
        return absoluteUSDValue >= minimumTokenUSDValue
    }
}

struct WalletTransactionMetadata: Hashable, Sendable {
    let transactionHash: String?
    let blockchainIdentifier: String?
    let date: Date?
    let fromAddress: String?
    let toAddress: String?
    let blockNumber: Int64?
    let blockHash: String?
    let contractAddress: String?
    let tokenName: String?
    let tokenDecimals: Int?
    let logIndex: Int?
    let networkFee: Decimal?
    let networkFeeFiatValue: Decimal?
    let networkFeeSymbol: String?
    let gasPriceGwei: Decimal?
    let gasLimit: Int64?
    let gasUsed: Int64?
    let nonce: Int64?
    let transactionIndex: Int64?
    let transactionType: Int64?
    let inputData: String?
    let note: String?

    static let empty = WalletTransactionMetadata(
        transactionHash: nil,
        blockchainIdentifier: nil,
        date: nil,
        fromAddress: nil,
        toAddress: nil,
        blockNumber: nil,
        blockHash: nil,
        contractAddress: nil,
        tokenName: nil,
        tokenDecimals: nil,
        logIndex: nil,
        networkFee: nil,
        networkFeeFiatValue: nil,
        networkFeeSymbol: nil,
        gasPriceGwei: nil,
        gasLimit: nil,
        gasUsed: nil,
        nonce: nil,
        transactionIndex: nil,
        transactionType: nil,
        inputData: nil,
        note: nil
    )
}

enum WalletTransactionNote {
    static let maximumUTF8Count = 1_000

    static func acceptsEditableInput(_ value: String) -> Bool {
        value.utf8.count <= maximumUTF8Count
    }

    static func normalized(_ value: String?) -> String? {
        guard
            let value,
            acceptsEditableInput(value)
        else {
            return nil
        }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum WalletTransactionStatus: Hashable, Sendable {
    case pending
    case confirmed
    case canceled
    case failed
    case notFound
    case replaced

    var localizedKey: String {
        switch self {
        case .pending:
            "wallet.activity.status.pending"
        case .confirmed:
            "wallet.activity.status.confirmed"
        case .canceled:
            "wallet.activity.status.canceled"
        case .failed:
            "wallet.activity.status.failed"
        case .notFound:
            "wallet.activity.status.not_found"
        case .replaced:
            "wallet.activity.status.replaced"
        }
    }

    var historyLocalizedKey: String? {
        switch self {
        case .confirmed:
            nil
        case .pending, .canceled, .failed, .notFound, .replaced:
            localizedKey
        }
    }
}

enum WalletTransactionKind: Hashable, Sendable {
    case received(assetSymbol: String)
    case sent(assetSymbol: String)
    case selfTransfer(assetSymbol: String)
    case swapped(sourceSymbol: String, destinationSymbol: String)

    func resolvingSelfTransfer(metadata: WalletTransactionMetadata) -> Self {
        switch self {
        case .selfTransfer, .swapped:
            return self
        case let .received(symbol), let .sent(symbol):
            guard let networkID = WalletNetworkSelectionOrdering.canonicalNetworkID(
                metadata.blockchainIdentifier
            ),
                // UTXO transactions may have multiple recipients and change.
                // Their history mapper must establish ownership of every output.
                BitcoinFamilyChain(rawValue: networkID) == nil,
                let from = metadata.fromAddress,
                let to = metadata.toAddress,
                let sender = SendRecipientAddressIdentity(address: from, networkID: networkID),
                let recipient = SendRecipientAddressIdentity(address: to, networkID: networkID),
                sender == recipient else { return self }
            return .selfTransfer(assetSymbol: symbol)
        }
    }

    var systemSymbol: String {
        switch self {
        case .received:
            "arrow.down"
        case .sent:
            "arrow.up"
        case .selfTransfer:
            "arrow.left.arrow.right"
        case .swapped:
            "arrow.left.arrow.right"
        }
    }

    var localizedTitle: String {
        switch self {
        case .received:
            WalletLocalization.string(
                "wallet.transaction.details.direction.received"
            )
        case .sent:
            WalletLocalization.string(
                "wallet.transaction.details.direction.sent"
            )
        case .selfTransfer:
            WalletLocalization.string(
                "wallet.activity.self_transfer.title"
            )
        case .swapped:
            WalletLocalization.string(
                "wallet.transaction.details.direction.swapped"
            )
        }
    }
}


extension WalletAsset {
    func formattedWalletFiat(using currency: WalletCurrencyContext) -> String {
        let converted = fiatValue * currency.ratePerUSD
        if converted > 0 && converted < Decimal(string: "0.01")! {
            return "< " + EnglishNumbers.currency(Decimal(string: "0.01")!, currencyCode: currency.code)
        }
        return EnglishNumbers.currency(fiatValue, using: currency)
    }
}
