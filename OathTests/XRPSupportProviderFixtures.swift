import Foundation
import GRDB
import Testing
import WalletCore
@testable import Aperture

actor XRPBalanceSnapshotProbe {
    private(set) var recordCount = 0
    private(set) var historyCount = -1
    private(set) var firstBalanceCount = -1
    private(set) var latestBalanceCount = -1
    private(set) var firstBalancesAreAuthoritative = false
    private(set) var latestBalancesAreAuthoritative = false

    func record(_ snapshot: XRPWalletSnapshot) {
        recordCount += 1
        historyCount = snapshot.history.count
        latestBalanceCount = snapshot.balances.count
        latestBalancesAreAuthoritative = snapshot.balancesAreAuthoritative
        if recordCount == 1 {
            firstBalanceCount = snapshot.balances.count
            firstBalancesAreAuthoritative =
                snapshot.balancesAreAuthoritative
        }
    }
}

actor XRPTransportProbe {
    private(set) var method: String?
    private(set) var parameterCount = -1
    private(set) var firstAccount: String?

    func response(for request: URLRequest) throws -> (Data, URLResponse) {
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        method = object["method"] as? String
        let params = try #require(object["params"] as? [[String: Any]])
        parameterCount = params.count
        firstAccount = params.first?["account"] as? String
        return try Self.response(
            for: request,
            result: nil,
            error: ["code": -32_600, "message": "fixture rejected"]
        )
    }

    private static func response(
        for request: URLRequest,
        result: [String: Any]?,
        error: [String: Any]?
    ) throws -> (Data, URLResponse) {
        var payload: [String: Any] = ["jsonrpc": "2.0", "id": 1]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (try JSONSerialization.data(withJSONObject: payload), response)
    }
}

actor XRPProviderFixture {
    enum Mode: Sendable {
        case snapshot
        case empty
        case send
    }

    private let mode: Mode
    private let sender: String
    private let recipient: String
    private let issuer: String
    private var methods: [String] = []
    private var submittedBlobBytes = 0
    private var accountTxLedgerMinimum: Int?

    init(mode: Mode, sender: String, recipient: String, issuer: String) {
        self.mode = mode
        self.sender = sender
        self.recipient = recipient
        self.issuer = issuer
    }

    func recordedMethods() -> [String] { methods }
    func submitBlobLength() -> Int { submittedBlobBytes }
    func accountTransactionLedgerMinimum() -> Int? {
        accountTxLedgerMinimum
    }

    func response(for request: URLRequest) throws -> (Data, URLResponse) {
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let method = try #require(object["method"] as? String)
        let params = try #require(object["params"] as? [[String: Any]])
        let parameter = params.first ?? [:]
        methods.append(method)
        if method == "account_tx" {
            accountTxLedgerMinimum = parameter["ledger_index_min"] as? Int
        }

        let result: [String: Any]
        switch (mode, method) {
        case (.empty, "account_info"), (.empty, "account_lines"), (.empty, "account_tx"):
            result = ["status": "error", "error": "actNotFound"]
        case (_, "account_info"):
            let account = parameter["account"] as? String
            result = [
                "account_data": [
                    "Account": account ?? sender,
                    "Balance": account == sender ? "50000000" : "2000000",
                    "Flags": 0,
                    "OwnerCount": account == sender ? 1 : 0,
                    "Sequence": account == sender ? 7 : 2
                ],
                "ledger_index": 100,
                "validated": true
            ]
        case (.snapshot, "account_lines"):
            result = [
                "lines": [[
                    "account": issuer,
                    "balance": "12.5000",
                    "currency": "USD",
                    "limit": "1000",
                    "limit_peer": "0",
                    "quality_in": 0,
                    "quality_out": 0
                ]]
            ]
        case (.send, "account_lines"):
            let account = parameter["account"] as? String
            result = [
                "lines": [[
                    "account": issuer,
                    "balance": account == sender ? "12.5" : "0",
                    "currency": "USD",
                    "limit": "1000",
                    "limit_peer": "0",
                    "quality_in": 0,
                    "quality_out": 0
                ]]
            ]
        case (.snapshot, "account_tx"):
            result = [
                "transactions": [
                    [
                        "ledger_index": 100,
                        "tx": [
                            "Account": sender,
                            "Amount": "1000000",
                            "Destination": recipient,
                            "DestinationTag": 42,
                            "Fee": "10",
                            "Sequence": 7,
                            "TransactionType": "Payment",
                            "date": 800_000_000,
                            "hash": "NATIVE_HASH"
                        ],
                        "meta": [
                            "TransactionResult": "tesSUCCESS",
                            "delivered_amount": "1000000"
                        ]
                    ],
                    [
                        "ledger_index": 99,
                        "tx": [
                            "Account": recipient,
                            "Amount": [
                                "currency": "USD",
                                "issuer": issuer,
                                "value": "2.5"
                            ],
                            "Destination": sender,
                            "Fee": "12",
                            "Sequence": 3,
                            "TransactionType": "Payment",
                            "date": 799_999_900,
                            "hash": "TOKEN_HASH"
                        ],
                        "meta": [
                            "TransactionResult": "tesSUCCESS",
                            "delivered_amount": [
                                "currency": "USD",
                                "issuer": issuer,
                                "value": "2.5"
                            ]
                        ]
                    ]
                ]
            ]
        case (_, "server_state"):
            result = [
                "state": [
                    "validated_ledger": [
                        "reserve_base": 1_000_000,
                        "reserve_inc": 200_000
                    ]
                ]
            ]
        case (_, "ledger_current"):
            result = ["ledger_current_index": 100]
        case (_, "fee"):
            result = ["drops": ["open_ledger_fee": "10"]]
        case (.send, "submit"):
            let blob = parameter["tx_blob"] as? String ?? ""
            submittedBlobBytes = blob.utf8.count
            result = ["engine_result": "tesSUCCESS"]
        default:
            Issue.record("Unexpected XRP fixture request: \(method)")
            result = ["status": "error", "error": "unexpectedFixture"]
        }
        return try Self.httpResponse(for: request, result: result)
    }

    private static func httpResponse(
        for request: URLRequest,
        result: [String: Any]
    ) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "result": result
        ]
        return (
            try JSONSerialization.data(withJSONObject: payload),
            response
        )
    }
}
