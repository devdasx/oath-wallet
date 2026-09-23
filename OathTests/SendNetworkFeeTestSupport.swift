import Foundation
@testable import Aperture

extension SendNetworkFeeTests {
    static var validQuoteData: Data {
        let formatter = ISO8601DateFormatter()
        let fetchedAt = Date().addingTimeInterval(-1)
        let expiresAt = fetchedAt.addingTimeInterval(30)
        return Data(
            """
        {
          "quote": {
            "networkID": "eth",
            "provider": "ankr",
            "fetchedAt": "\(formatter.string(from: fetchedAt))",
            "expiresAt": "\(formatter.string(from: expiresAt))",
            "tiers": [
              {
                "preset": "fastest",
                "model": "evm_eip1559",
                "primaryValue": "42000000000",
                "secondaryValue": "3000000000"
              },
              {
                "preset": "standard",
                "model": "evm_eip1559",
                "primaryValue": "35000000000",
                "secondaryValue": "2000000000"
              },
              {
                "preset": "economy",
                "model": "evm_eip1559",
                "primaryValue": "30000000000",
                "secondaryValue": "1000000000"
              }
            ]
          }
        }
        """.utf8
        )
    }

    static func bitcoinDraft(
        preparedNetworkFee: SendResolvedNetworkFee?
    ) -> SendDraft {
        SendDraft(
            request: .manualEntry(networkID: "bitcoin"),
            asset: SendAssetChoice(
                id: "bitcoin:native",
                name: "Bitcoin",
                symbol: "BTC",
                networkID: "bitcoin",
                networkName: "Bitcoin",
                blockchain: .bitcoin,
                contractAddress: nil,
                decimals: 8,
                logoSource: .nativeCoin(blockchain: .bitcoin),
                networkLogoSource: .network(blockchain: .bitcoin),
                balance: 1,
                fiatValue: 1,
                balanceAtomic: "100000000",
                sourceAddress: nil
            ),
            recipient: "bc1qexample",
            amount: "0.1",
            note: nil,
            preparedNetworkFee: preparedNetworkFee
        )
    }

    static func customFeeDraft(
        networkID: String,
        blockchain: WalletBlockchain,
        policy: SendNetworkFeePolicy
    ) -> SendDraft {
        SendDraft(
            request: .manualEntry(networkID: networkID),
            asset: SendAssetChoice(
                id: "\(networkID):native",
                name: "Native Asset",
                symbol: "COIN",
                networkID: networkID,
                networkName: "Mainnet",
                blockchain: blockchain,
                contractAddress: nil,
                decimals: 18,
                logoSource: .nativeCoin(blockchain: blockchain),
                networkLogoSource: .network(blockchain: blockchain),
                balance: 1,
                fiatValue: 1
            ),
            recipient: "recipient",
            amount: "0.1",
            note: nil,
            feePolicy: policy
        )
    }
}

actor SendNetworkFeeRequestSequence {
    private let responses: [(status: Int, data: Data)]
    private var index = 0

    init(responses: [(status: Int, data: Data)]) {
        self.responses = responses
    }

    func execute(_ request: URLRequest) throws -> (Data, URLResponse) {
        guard !responses.isEmpty,
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: responses[min(index, responses.count - 1)].status,
                  httpVersion: nil,
                  headerFields: nil
              )
        else {
            throw URLError(.badServerResponse)
        }
        let item = responses[min(index, responses.count - 1)]
        index += 1
        return (item.data, response)
    }

    func requestCount() -> Int { index }
}

actor SendNetworkFeeOperationProbe {
    private let error: Error
    private var count = 0

    init(error: Error) {
        self.error = error
    }

    func run() throws -> SendNetworkFeeQuote {
        count += 1
        throw error
    }

    func attemptCount() -> Int { count }
}

enum SendNetworkFeeDirectProviderProbeError: Error {
    case unavailable
}

actor SendNetworkFeeTimeoutProbe {
    private var started = false
    private var cancelled = false

    func markStarted() { started = true }
    func markCancelled() { cancelled = true }
    func didStart() -> Bool { started }
    func wasCancelled() -> Bool { cancelled }
}
