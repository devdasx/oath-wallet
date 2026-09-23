import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct AptosPrunedHistoryTests {
    fileprivate static let owner =
        "0xe9c4d0b6fe32a5cc8ebd1e9ad5b54a0276a57f2d081dcb5e30342319963626c3"
    private static let recipient =
        "0xd503b95164384a5ebbccbb5c4bdc8b4a5893d9651e9953abda8e1c22fcc1181d"
    private static let canonicalHash =
        "0x" + String(repeating: "a", count: 64)
    private static let material = AptosAccountMaterial(
        address: owner,
        publicKey: "aptos-pruned-history-public-fixture",
        derivationPath: AptosConstants.derivationPath
    )

    @Test
    func prunedFullnodeDetailKeepsIndexedHistoryAuthoritative()
        async throws
    {
        let snapshot = try await Self.client().loadSnapshot(
            material: Self.material
        )

        #expect(snapshot.balancesAreAuthoritative)
        #expect(snapshot.historyIsAuthoritative)
        #expect(snapshot.providerFailureCodes.isEmpty)
        let item = try #require(snapshot.history.first)
        #expect(item.transactionVersion == 42)
        #expect(item.transactionHash == "42")
        #expect(item.sender == Self.owner)
        #expect(item.recipient == nil)
        #expect(item.signedAmountText == "-0.015")
        #expect(item.networkFeeText == nil)
        #expect(abs(item.timestamp - 1_785_628_800.123_456) < 0.001)

        let database = try WalletDatabase.temporary()
        let walletID = "aptos-pruned-history-wallet"
        try await Self.insertWalletAndAccount(
            database: database,
            walletID: walletID
        )
        try await database.saveAptosSnapshot(snapshot, walletID: walletID)
        let records = try await Self.storedTransactions(
            database: database,
            walletID: walletID
        )
        let stored = try #require(records.first)
        #expect(stored.transactionHash == "42")
        #expect(stored.blockNumber == 42)
        #expect(
            abs((try #require(stored.timestamp)) - item.timestamp)
                < 0.000_001
        )
        #expect(stored.displayTime.isEmpty)
        #expect(
            WalletTransactionExplorer.url(
                transactionHash: stored.transactionHash,
                networkID: stored.networkID
            )?.absoluteString
                == "https://explorer.aptoslabs.com/txn/42?network=mainnet"
        )
    }

    @Test
    func indexerOnlyRefreshPreservesRicherCachedTransactionDetails()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let walletID = "aptos-pruned-history-preservation-wallet"
        try await Self.insertWalletAndAccount(
            database: database,
            walletID: walletID
        )
        try await database.saveAptosSnapshot(
            Self.snapshot(
                item: Self.historyItem(
                    transactionReference: Self.canonicalHash,
                    recipient: Self.recipient,
                    networkFee: "0.00001"
                )
            ),
            walletID: walletID
        )
        let submittedRecordID = "locally-submitted-aptos-record"
        try await database.pool.write { connection in
            try connection.execute(
                sql: "UPDATE transactions SET id = ? WHERE transactionHash = ?",
                arguments: [submittedRecordID, Self.canonicalHash]
            )
        }
        try await database.saveAptosSnapshot(
            Self.snapshot(
                item: Self.historyItem(
                    transactionReference: "42",
                    recipient: nil,
                    networkFee: nil
                )
            ),
            walletID: walletID
        )

        let records = try await Self.storedTransactions(
            database: database,
            walletID: walletID
        )
        let stored = try #require(records.first)
        #expect(records.count == 1)
        #expect(stored.id == submittedRecordID)
        #expect(stored.transactionHash == Self.canonicalHash)
        #expect(stored.normalizedTransactionHash == Self.canonicalHash)
        #expect(stored.fromAddress == Self.owner)
        #expect(stored.toAddress == Self.recipient)
        #expect(stored.counterpartyAddress == Self.recipient)
        #expect(stored.networkFee == "0.00001")
    }

    @Test
    func unavailableTimestampStaysEmptyInsteadOfShowingStatus() async throws {
        let database = try WalletDatabase.temporary()
        let walletID = "aptos-missing-history-time-wallet"
        try await Self.insertWalletAndAccount(
            database: database,
            walletID: walletID
        )
        let item = AptosHistoryItem(
            id: "42:0",
            transactionVersion: 42,
            transactionHash: "42",
            timestamp: 0,
            failed: false,
            sender: Self.owner,
            recipient: nil,
            owner: Self.owner,
            metadata: AptosTokenCatalog.native,
            signedAmountText: "-0.015",
            networkFeeText: nil,
            entryFunction: "0x1::aptos_account::transfer"
        )
        try await database.saveAptosSnapshot(
            Self.snapshot(item: item),
            walletID: walletID
        )
        let records = try await Self.storedTransactions(
            database: database,
            walletID: walletID
        )
        let stored = try #require(records.first)
        #expect(stored.timestamp == nil)
        #expect(stored.displayTime.isEmpty)

        // Old app versions persisted the localized confirmation status in
        // this field. The presentation mapper must ignore that stale value.
        try await database.pool.write { connection in
            try connection.execute(
                sql: "UPDATE transactions SET displayTime = ? WHERE id = ?",
                arguments: ["Transaction Confirmed", stored.id]
            )
        }
        let activity = try #require(
            try await database.cachedWalletActivitySlice(walletID: walletID)
        )
        let transaction = try #require(activity.transactions.first)
        #expect(transaction.time.isEmpty)
        #expect(transaction.metadata.date == nil)
    }

    private static func client() -> AptosAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AptosPrunedHistoryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return AptosAPIClient(
            rest: AptosRESTTransport(
                baseURL: URL(
                    string: "https://aptos-pruned.example.test/v1"
                )!,
                session: session
            ),
            indexer: AptosIndexerTransport(
                endpoint: URL(
                    string: "https://aptos-pruned.example.test/graphql"
                )!,
                session: session,
                router: AdaptiveProviderRouter()
            )
        )
    }

    private static func historyItem(
        transactionReference: String,
        recipient: String?,
        networkFee: String?
    ) -> AptosHistoryItem {
        AptosHistoryItem(
            id: "42:0",
            transactionVersion: 42,
            transactionHash: transactionReference,
            timestamp: 1_785_628_800,
            failed: false,
            sender: owner,
            recipient: recipient,
            owner: owner,
            metadata: AptosTokenCatalog.native,
            signedAmountText: "-0.015",
            networkFeeText: networkFee,
            entryFunction: "0x1::aptos_account::transfer"
        )
    }

    private static func snapshot(item: AptosHistoryItem) -> AptosWalletSnapshot {
        AptosWalletSnapshot(
            material: material,
            balances: [],
            history: [item],
            balancesAreAuthoritative: false,
            historyIsAuthoritative: true,
            providerFailureCodes: []
        )
    }

    private static func insertWalletAndAccount(
        database: WalletDatabase,
        walletID: String
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await database.pool.write { connection in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Aptos Pruned History Test Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: nil,
                isSelected: false,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: nil,
                archivedAt: nil
            ).insert(connection)
            try DBWalletAccountRecord(
                id: "\(walletID):aptos:0",
                walletID: walletID,
                networkID: AptosConstants.networkID,
                address: material.address,
                normalizedAddress: material.address,
                label: AptosConstants.accountLabel,
                derivationPath: material.derivationPath,
                accountIndex: 0,
                publicKey: material.publicKey,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(connection)
        }
    }

    private static func storedTransactions(
        database: WalletDatabase,
        walletID: String
    ) async throws -> [DBTransactionRecord] {
        try await database.pool.read { connection in
            try DBTransactionRecord
                .filter(Column("accountID") == "\(walletID):aptos:0")
                .fetchAll(connection)
        }
    }
}

private final class AptosPrunedHistoryURLProtocol: URLProtocol,
    @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            fail(URLError(.badURL))
            return
        }
        switch url.path {
        case "/v1/view":
            respond(status: 200, object: ["200000000"])
        case "/v1/transactions/by_version/42":
            respond(
                status: 410,
                object: [
                    "message": "Ledger version(42) has been pruned",
                    "error_code": "version_pruned",
                    "vm_error_code": NSNull()
                ]
            )
        case "/graphql":
            respondGraphQL()
        default:
            fail(URLError(.unsupportedURL))
        }
    }

    override func stopLoading() {}

    private func respondGraphQL() {
        guard let body = Self.bodyData(from: request),
              let object = try? JSONSerialization.jsonObject(with: body)
                    as? [String: Any],
              let query = object["query"] as? String else {
            fail(URLError(.cannotParseResponse))
            return
        }
        if query.contains("current_fungible_asset_balances") {
            respond(
                status: 200,
                object: [
                    "data": [
                        "current_fungible_asset_balances": [
                            Self.nativeBalance
                        ]
                    ]
                ]
            )
        } else if query.contains("fungible_asset_activities") {
            respond(
                status: 200,
                object: [
                    "data": [
                        "fungible_asset_activities": [Self.activity]
                    ]
                ]
            )
        } else {
            fail(URLError(.unsupportedURL))
        }
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: bufferSize
        )
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func respond(status: Int, object: Any) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else {
            fail(URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }

    private static var nativeBalance: [String: Any] {
        [
            "storage_id": "0x" + String(repeating: "0", count: 63) + "1",
            "amount": "200000000",
            "asset_type": AptosConstants.nativeCoinType,
            "token_standard": "v1",
            "is_primary": true,
            "is_frozen": false,
            "metadata": [
                "asset_type": AptosConstants.nativeCoinType,
                "name": "Aptos",
                "symbol": "APT",
                "decimals": 8,
                "icon_uri": NSNull(),
                "token_standard": "v1"
            ]
        ]
    }

    private static var activity: [String: Any] {
        [
            "transaction_version": "42",
            "event_index": "0",
            "owner_address": AptosPrunedHistoryTests.owner,
            "asset_type": AptosConstants.nativeCoinType,
            "amount": "1500000",
            "type": "withdraw",
            "is_transaction_success": true,
            "entry_function_id_str": "0x1::aptos_account::transfer",
            "transaction_timestamp": "2026-08-02T00:00:00.123456Z",
            "metadata": [
                "asset_type": AptosConstants.nativeCoinType,
                "name": "Aptos",
                "symbol": "APT",
                "decimals": 8,
                "icon_uri": NSNull(),
                "token_standard": "v1"
            ]
        ]
    }
}
