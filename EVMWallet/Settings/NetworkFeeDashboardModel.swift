import Foundation
import GRDB
import Observation

enum NetworkFeeQuoteSource: String, Sendable {
    case updated, cached, fallback
}

struct NetworkFeeDashboardEntry: Identifiable, Sendable {
    let network: ReceiveNetwork
    let quote: SendNetworkFeeQuote
    let source: NetworkFeeQuoteSource
    var id: String { network.id }

    static func make(network: ReceiveNetwork, record: WalletNetworkFeeRecord?, now: Date = Date()) throws -> Self {
        let quote = try WalletNetworkFeeCachePolicy.resolvedQuote(record: record, networkID: network.id, now: now)
        let source: NetworkFeeQuoteSource = quote.provider == SendNetworkFeeAPIClient.builtInDefaultProvider
            ? .fallback : (quote.expiresAt > now && record?.lastAttemptSucceeded == true ? .updated : .cached)
        return Self(network: network, quote: quote, source: source)
    }
}

struct NetworkFeeDashboardValue {
    let value: String
    let unit: String
    let kindKey: String
    let detail: String?
    private let nativeAmount: Decimal?
    private let currencyUnit: String

    init(network: ReceiveNetwork, tier: SendNetworkFeeTier) {
        // Convert the quoted unit itself, never assume a transaction size or
        // present a per-unit price as the cost of a complete transfer.
        let decimals = tier.model == .solanaPriority
            ? 15 : SendNetworkFeeEstimator.nativeDecimals(for: tier.model)
        nativeAmount = SendAtomicAmount.isCanonical(tier.primaryValue)
            ? Decimal(string: SendDecimalAmount.userUnits(fromAtomicUnits: tier.primaryValue, decimals: decimals),
                      locale: Locale(identifier: "en_US_POSIX")) : nil
        currencyUnit = switch tier.model {
        case .evmEIP1559, .evmLegacy: "/gas"
        case .utxoPerVByte: "/vB"
        case .solanaPriority: "/CU"
        case .tronProtocol: "/energy"
        default: ""
        }
        let rate = "network_fees.rate"
        let budget = "network_fees.budget"
        let estimate = "network_fees.estimate"
        switch tier.model {
        case .evmEIP1559, .evmLegacy:
            let maximumText = Self.number(tier.primaryValue, decimals: 9)
            value = maximumText
            unit = "Gwei"
            kindKey = rate
            detail = tier.secondaryValue.map {
                EnglishNumbers.localized("send.network_fee.rate.evm_eip1559", maximumText, Self.number($0, decimals: 9))
            }
        case .utxoPerVByte:
            value = Self.number(tier.primaryValue)
            unit = switch network.id {
            case "litecoin": "litoshi/vB"
            case "dogecoin": "koinu/vB"
            default: "sat/vB"
            }
            kindKey = rate
            detail = nil
        case .solanaPriority:
            value = Self.number(tier.primaryValue)
            unit = "µ-lamports/CU"
            kindKey = "network_fees.priority"
            detail = EnglishNumbers.localized("send.network_fee.rate.solana", value)
        case .tronProtocol:
            value = Self.number(tier.primaryValue)
            unit = "sun/energy"
            kindKey = rate
            detail = EnglishNumbers.localized("send.network_fee.rate.tron", value, Self.number(tier.secondaryValue ?? "0"))
        case .tonProtocol, .suiProtocol, .aptosProtocol, .nearProtocol:
            let decimals = SendNetworkFeeEstimator.nativeDecimals(for: tier.model)
            value = Self.number(tier.primaryValue, decimals: decimals)
            unit = network.symbol
            kindKey = budget
            detail = tier.secondaryValue.flatMap { secondary in
                switch tier.model {
                case .suiProtocol: "\(Self.number(secondary)) MIST/gas"
                case .aptosProtocol: "\(Self.number(secondary)) octa/gas"
                case .nearProtocol: "\(Self.number(secondary)) yoctoNEAR/gas"
                default: nil
                }
            }
        case .xrpProtocol, .stellarProtocol:
            value = Self.number(tier.primaryValue, decimals: SendNetworkFeeEstimator.nativeDecimals(for: tier.model))
            unit = network.symbol
            kindKey = estimate
            detail = nil
        }
    }

    var combined: String { "\(value) \(unit)" }

    func localCurrencyValue(nativeUnitUSDPrice: Decimal?, using currency: WalletCurrencyContext) -> String? {
        guard let nativeAmount, !nativeAmount.isNaN, nativeAmount >= 0,
              let nativeUnitUSDPrice, !nativeUnitUSDPrice.isNaN, nativeUnitUSDPrice > 0,
              let formatted = EnglishNumbers.networkFeeDashboardCurrency(
                nativeAmount * nativeUnitUSDPrice, using: currency
              ) else { return nil }
        return formatted + currencyUnit
    }

    private static func number(_ atomic: String, decimals: Int = 0) -> String {
        let text = SendDecimalAmount.userUnits(fromAtomicUnits: atomic, decimals: decimals)
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return text }
        return EnglishNumbers.decimal(value, maximumFractionDigits: max(9, decimals))
    }
}

extension EnglishNumbers {
    /// Preserve useful precision for small fees without displaying a nonzero
    /// fee as free. Currency conversion and rounding both stay in base 10.
    static func networkFeeDashboardCurrency(_ usdValue: Decimal, using context: WalletCurrencyContext) -> String? {
        guard !usdValue.isNaN, usdValue >= 0,
              !context.ratePerUSD.isNaN, context.ratePerUSD > 0 else { return nil }
        let localValue = usdValue * context.ratePerUSD
        guard !localValue.isNaN else { return nil }
        let minimum = Decimal(sign: .plus, exponent: -6, significand: 1)
        let belowPrecision = localValue > 0 && localValue < minimum
        let amount = decimal(belowPrecision ? minimum : localValue,
                             minimumFractionDigits: 2, maximumFractionDigits: 6)
        guard let formatted = notificationCurrency(amount, currencyCode: context.code) else { return nil }
        return (belowPrecision ? "<" : "") + formatted
    }
}

@MainActor @Observable
final class NetworkFeeDashboardModel {
    typealias PriceLoader = @Sendable (WalletAsset) async throws -> AssetUSDPrice
    private(set) var records: [String: WalletNetworkFeeRecord] = [:]
    private(set) var nativeUSDPrices: [String: Decimal] = [:]
    private(set) var isRefreshing = false
    private(set) var readFailed = false
    @ObservationIgnored private let repository: SendNetworkFeeQuoteRepository
    @ObservationIgnored private let priceLoader: PriceLoader?

    init(repository: SendNetworkFeeQuoteRepository = .shared, priceLoader: PriceLoader? = nil) {
        self.repository = repository
        self.priceLoader = priceLoader
    }

    func entries(now: Date = Date(), search: String = "") -> [NetworkFeeDashboardEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReceiveNetworkCatalog.catalogNetworkIdentifiers.compactMap { id in
            guard let network = ReceiveNetworkCatalog.catalogNetwork(for: id) else { return nil }
            guard query.isEmpty || network.localizedName.localizedStandardContains(query)
                || network.symbol.localizedStandardContains(query) else { return nil }
            return try? NetworkFeeDashboardEntry.make(network: network, record: records[network.id], now: now)
        }.sorted { $0.network.localizedName.localizedStandardCompare($1.network.localizedName) == .orderedAscending }
    }

    func observe(database: WalletDatabase) async {
        do {
            for try await values in database.networkFeeRecords() {
                guard !Task.isCancelled else { return }
                records = Dictionary(uniqueKeysWithValues: values.map { ($0.networkID, $0) })
                readFailed = false
            }
        } catch is CancellationError {
        } catch {
            records = [:]
            readFailed = true
        }
    }

    func refresh(database: WalletDatabase, force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Market prices never hold up quote persistence. Each fee response is
        // committed by the repository and published through observe immediately.
        async let fees: Void = repository.refresh(database: database, force: force)
        async let prices: Void = refreshPrices(database: database)
        _ = await (fees, prices)
    }

    private func refreshPrices(database: WalletDatabase) async {
        guard !database.isPerformingAppReset() else { return }
        let generation = database.applicationSettingsPersistenceGeneration()
        let assets = ReceiveNetworkCatalog.catalogNetworkIdentifiers.compactMap { id -> (String, WalletAsset)? in
            guard let network = ReceiveNetworkCatalog.catalogNetwork(for: id) else { return nil }
            return (id, Self.nativePriceAsset(for: network))
        }
        // A single-chain wallet may not have rows for the other native coins.
        // Seed public metadata only, so their prices can use the existing cache;
        // this does not add holdings or accounts to any wallet.
        try? await database.pool.write { db in
            guard database.applicationSettingsWriteGate(expectedGeneration: generation) == .allowed else { return }
            let now = Date().timeIntervalSince1970
            for (id, asset) in assets {
                try DBAssetRecord(id: asset.id, networkID: id, assetType: DatabaseAssetType.native.rawValue,
                                  contractAddress: "", normalizedContractAddress: "", name: asset.name,
                                  symbol: asset.symbol, decimals: asset.decimals,
                                  trustWalletBlockchain: asset.network?.rawValue, trustWalletContractAddress: nil,
                                  isVerified: true, isSpam: false, createdAt: now, updatedAt: now,
                                  metadataUpdatedAt: nil).insert(db, onConflict: .ignore)
            }
        }
        if let cached = try? await database.pool.read({ db in
            var prices: [String: Decimal] = [:]
            for id in ReceiveNetworkCatalog.catalogNetworkIdentifiers {
                let assetID = AssetIdentityKey.make(networkID: id, contractAddress: nil)
                if let record = try WalletDatabase.latestValidUSDPriceRecord(assetID: assetID, database: db),
                   let price = Decimal(string: record.price, locale: Locale(identifier: "en_US_POSIX")),
                   !price.isNaN, price > 0 {
                    prices[id] = price
                }
            }
            return prices
        }) {
            guard !Task.isCancelled,
                  database.applicationSettingsWriteGate(expectedGeneration: generation) == .allowed else { return }
            nativeUSDPrices.merge(cached) { _, saved in saved }
        }
        let client = AssetPriceClient(database: database)
        let load = priceLoader ?? { try await client.usdPrice(for: $0) }
        await withTaskGroup(of: (String, Decimal?).self) { group in
            var iterator = assets.makeIterator()
            func enqueue(_ request: (String, WalletAsset)) {
                group.addTask {
                    let (id, asset) = request
                    let quote = try? await load(asset)
                    let price = quote.flatMap { quote -> Decimal? in
                        guard quote.assetID == asset.id, !quote.price.isNaN, quote.price > 0 else { return nil }
                        return quote.price
                    }
                    return (id, price)
                }
            }
            for _ in 0..<min(4, assets.count) {
                if let asset = iterator.next() { enqueue(asset) }
            }
            for await (id, price) in group {
                guard !Task.isCancelled,
                      database.applicationSettingsWriteGate(expectedGeneration: generation) == .allowed else {
                    group.cancelAll()
                    break
                }
                if let price { nativeUSDPrices[id] = price }
                if let asset = iterator.next() { enqueue(asset) }
            }
        }
    }

    static func nativePriceAsset(for network: ReceiveNetwork) -> WalletAsset {
        let decimals = BitcoinFamilyChain.allCases.contains { $0.networkID == network.id }
            ? 8 : ReceiveToken.nativeAsset(for: network).variants.first?.decimals
        return WalletAsset(id: AssetIdentityKey.make(networkID: network.id, contractAddress: nil),
                           name: network.nativeAssetName, symbol: network.symbol,
                           logoSource: .nativeCoin(blockchain: network.blockchain), network: network.blockchain,
                           balance: 0, fiatValue: 0, decimals: decimals)
    }
}
