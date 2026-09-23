import Foundation

struct TONAPICompositeSnapshot: Decodable, Sendable {
    let account: TONAPIAccount
    let jettons: TONAPIJettonBalances
    let events: TONAPIEvents
    let rates: TONAPIRates
    let sources: Sources?

    struct Sources: Decodable, Sendable {
        let jettonsComplete: Bool
        let eventsComplete: Bool
        let ratesComplete: Bool
        let failures: [String]
    }
}

struct TONAPIAccount: Decodable, Sendable {
    let address: String
    let balance: TONAPINumber
    let status: String?
    let isScam: Bool?

    private enum CodingKeys: String, CodingKey {
        case address, balance, status
        case isScam = "is_scam"
    }
}

enum TONAPINumber: Decodable, Sendable {
    case integer(String)
    case decimal(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = value.contains(".") ? .decimal(value) : .integer(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(String(value))
        } else if let value = try? container.decode(Decimal.self) {
            self = .decimal(NSDecimalNumber(decimal: value).stringValue)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an exact TON number."
            )
        }
    }

    var text: String {
        switch self {
        case let .integer(value), let .decimal(value): value
        }
    }
}

struct TONAPIJettonBalances: Decodable, Sendable {
    let balances: [Balance]

    struct Balance: Decodable, Sendable {
        let balance: String
        let price: Price?
        let walletAddress: TONAPIAddress
        let jetton: Jetton

        private enum CodingKeys: String, CodingKey {
            case balance, price, jetton
            case walletAddress = "wallet_address"
        }
    }

    struct Price: Decodable, Sendable {
        let prices: [String: TONAPINumber]
    }

    struct Jetton: Decodable, Sendable {
        let address: String
        let name: String
        let symbol: String
        let decimals: Int
        let verification: String?
    }
}

struct TONAPIAddress: Decodable, Sendable {
    let address: String
    let isScam: Bool?

    private enum CodingKeys: String, CodingKey {
        case address
        case isScam = "is_scam"
    }
}

struct TONAPIEvents: Decodable, Sendable {
    let events: [Event]
    let nextFrom: TONAPINumber?

    private enum CodingKeys: String, CodingKey {
        case events
        case nextFrom = "next_from"
    }

    struct Event: Decodable, Sendable {
        let eventID: String
        let timestamp: Double
        let actions: [Action]
        let isScam: Bool?
        let inProgress: Bool?
        let lt: TONAPINumber?

        private enum CodingKeys: String, CodingKey {
            case timestamp, actions, lt
            case eventID = "event_id"
            case isScam = "is_scam"
            case inProgress = "in_progress"
        }
    }

    struct Action: Decodable, Sendable {
        let type: String
        let status: String?
        let tonTransfer: TonTransfer?
        let jettonTransfer: JettonTransfer?

        private enum CodingKeys: String, CodingKey {
            case type, status
            case tonTransfer = "TonTransfer"
            case jettonTransfer = "JettonTransfer"
        }
    }

    struct TonTransfer: Decodable, Sendable {
        let sender: TONAPIAddress
        let recipient: TONAPIAddress
        let amount: TONAPINumber
    }

    struct JettonTransfer: Decodable, Sendable {
        let sender: TONAPIAddress?
        let recipient: TONAPIAddress?
        let amount: String
        let jetton: TONAPIJettonBalances.Jetton
    }
}

struct TONAPIRates: Decodable, Sendable {
    let rates: [String: Rate]

    struct Rate: Decodable, Sendable {
        let prices: [String: TONAPINumber]
    }
}

struct TONAPISeqno: Decodable, Sendable {
    let seqno: Int
}

struct TONAPIJettonWalletMethodResult: Decodable, Sendable {
    let success: Bool
    let exitCode: Int
    let decoded: Decoded?

    enum CodingKeys: String, CodingKey {
        case success
        case exitCode = "exit_code"
        case decoded
    }

    struct Decoded: Decodable, Sendable {
        let jettonWalletAddress: String

        enum CodingKeys: String, CodingKey {
            case jettonWalletAddress = "jetton_wallet_address"
        }
    }
}
