import Foundation
import OathDiagnostics

/// Mainnet-only fee recovery. No addresses, transactions or credentials are
/// sent to these public endpoints. Failed providers never become a guessed fee.
public struct BitcoinFeeFallback: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> Data
    private let fetch: Fetch
    public init() {
        fetch = { request in
            let (data,response) = try await DiagnosticHTTP.data(for: request, session: .shared)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count <= 65_536 else { throw BitcoinSendError.feeUnavailable }
            return data
        }
    }
    init(fetch: @escaping Fetch) { self.fetch = fetch }

    public func rate(primary: @Sendable () async throws -> Int64) async throws -> Int64 {
        do {
            let rate = try await primary()
            guard UTXONetwork.bitcoin.sendFeeRates.contains(rate) else { throw BitcoinSendError.feeUnavailable }
            try Task.checkCancellation(); return rate
        } catch { OathDiagnostics.record(error, component: "send", operation: "fee_electrum", context: ["chain":"bitcoin", "stage":"quote"]);
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
        }
        for source in Source.allCases {
            do {
                var request = URLRequest(url: source.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let data = try await fetch(request)
                try Task.checkCancellation()
                return try Self.decode(data, source: source)
            } catch { OathDiagnostics.record(error, component: "send", operation: "fee_http_fallback", context: ["chain":"bitcoin", "stage":"quote", "host":source.url.host!]);
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            }
        }
        throw BitcoinSendError.feeUnavailable
    }
    enum Source: CaseIterable {
        case mempool, blockstream
        var url: URL {
            URL(string: self == .mempool ? "https://mempool.space/api/v1/fees/recommended" : "https://blockstream.info/api/fee-estimates")!
        }
    }
    static func decode(_ data: Data, source: Source) throws -> Int64 {
        guard data.count <= 65_536 else { throw BitcoinSendError.feeUnavailable }
        let values = try JSONDecoder().decode([String:Decimal].self, from: data)
        let quote: Decimal
        switch source {
        case .mempool:
            guard let halfHour = values["halfHourFee"], let minimum = values["minimumFee"],
                  minimum >= 0, halfHour > 0 else { throw BitcoinSendError.feeUnavailable }
            quote = max(halfHour,minimum)
        case .blockstream:
            guard let value = values["3"] ?? values["2"] ?? values["1"] else { throw BitcoinSendError.feeUnavailable }
            quote = value
        }
        guard !quote.isNaN, quote > 0, quote <= Decimal(UTXONetwork.bitcoin.sendFeeRates.upperBound)/1000 else { throw BitcoinSendError.feeUnavailable }
        var scaled = quote*1000, rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .up)
        return max(UTXONetwork.bitcoin.sendFeeRates.lowerBound,NSDecimalNumber(decimal:rounded).int64Value)
    }
}
