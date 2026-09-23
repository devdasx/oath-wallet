import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct TrackedEVMTokenBalanceTests {
    private let walletID = "tracked-token-wallet"
    private let accountID = "tracked-token-eth-account"
    private let ownerAddress =
        "0x1111111111111111111111111111111111111111"
    private let trackedContract =
        "0x3333333333333333333333333333333333333333"
    private let ordinaryContract =
        "0x4444444444444444444444444444444444444444"

    @Test
    func collectorReturnsExactAndZeroBalancesWhileIsolatingFailure()
        async throws {
        let exactContract =
            "0x5555555555555555555555555555555555555555"
        let zeroContract =
            "0x6666666666666666666666666666666666666666"
        let failedContract =
            "0x7777777777777777777777777777777777777777"
        let rpc = TrackedTokenRPCStub(
            chainIDHex: "0x1",
            balancesByContract: [
                exactContract: "0x114d243b",
                zeroContract: "0x0"
            ],
            failedContracts: [failedContract]
        )
        let service = TrackedEVMTokenBalanceService {
            networkID in
            guard networkID == "eth" else {
                throw TrackedTokenRPCStubError.unavailable
            }
            return rpc
        }
        let exact = target(
            assetID: "eth:exact",
            contract: exactContract,
            decimals: 6
        )
        let zero = target(
            assetID: "eth:zero",
            contract: zeroContract,
            decimals: 18
        )
        let failed = target(
            assetID: "eth:failed",
            contract: failedContract,
            decimals: 18
        )

        let batch = try await service.loadBalances(
            for: [failed, zero, exact]
        )
        let updates = Dictionary(
            uniqueKeysWithValues: batch.updates.map {
                ($0.holdingID, $0)
            }
        )

        #expect(updates[exact.holdingID]?.balanceAtomic == "290268219")
        #expect(updates[exact.holdingID]?.balanceText == "290.268219")
        #expect(updates[zero.holdingID]?.balanceAtomic == "0")
        #expect(updates[zero.holdingID]?.balanceText == "0")
        #expect(updates[failed.holdingID] == nil)
        #expect(batch.failedHoldingIDs == [failed.holdingID])
    }

    @Test
    func collectorRejectsBalancesFromUnexpectedChain() async throws {
        let target = target(
            assetID: "eth:wrong-chain",
            contract: trackedContract,
            decimals: 6
        )
        let rpc = TrackedTokenRPCStub(
            chainIDHex: "0x89",
            balancesByContract: [trackedContract: "0x1"],
            failedContracts: []
        )
        let service = TrackedEVMTokenBalanceService { _ in rpc }

        let batch = try await service.loadBalances(for: [target])

        #expect(batch.updates.isEmpty)
        #expect(batch.failedHoldingIDs == [target.holdingID])
    }

    @Test
    func collectorRetriesOnlyTransientlyFailedContracts() async throws {
        let firstContract =
            "0x8888888888888888888888888888888888888888"
        let secondContract =
            "0x9999999999999999999999999999999999999999"
        let rpc = TransientTrackedTokenRPCStub(
            balancesByContract: [
                firstContract: "0xa",
                secondContract: "0x14"
            ],
            initiallyFailedContracts: [secondContract]
        )
        let service = TrackedEVMTokenBalanceService(
            maximumConcurrentTokensPerNetwork: 6,
            chainIDCache: TrackedEVMChainIDCache()
        ) { _ in rpc }
        let first = target(
            assetID: "eth:first-pass",
            contract: firstContract,
            decimals: 0
        )
        let retried = target(
            assetID: "eth:retried",
            contract: secondContract,
            decimals: 0
        )

        let batch = try await service.loadBalances(for: [first, retried])

        #expect(batch.failedHoldingIDs.isEmpty)
        #expect(batch.updates.count == 2)
        #expect(await rpc.requestCount(for: firstContract) == 1)
        #expect(await rpc.requestCount(for: secondContract) == 2)
    }

    @Test
    func collectorSerializesFinalRetryAfterTwoTransientFailures()
        async throws {
        let contract =
            "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let rpc = RepeatedTransientTrackedTokenRPCStub(
            balancesByContract: [contract: "0x2a"],
            failureAttemptsByContract: [contract: 2]
        )
        let service = TrackedEVMTokenBalanceService(
            maximumConcurrentTokensPerNetwork: 6,
            chainIDCache: TrackedEVMChainIDCache()
        ) { _ in rpc }
        let target = target(
            assetID: "eth:final-retry",
            contract: contract,
            decimals: 0
        )

        let batch = try await service.loadBalances(for: [target])

        #expect(batch.failedHoldingIDs.isEmpty)
        #expect(batch.updates.first?.balanceAtomic == "42")
        #expect(await rpc.requestCount(for: contract) == 3)
    }

    @Test
    func collectorCachesValidatedChainIdentityAcrossRefreshes() async throws {
        let rpc = TrackedTokenRPCStub(
            chainIDHex: "0x1",
            balancesByContract: [trackedContract: "0x1"],
            failedContracts: []
        )
        let service = TrackedEVMTokenBalanceService(
            chainIDCache: TrackedEVMChainIDCache()
        ) { _ in rpc }
        let target = target(
            assetID: "eth:cached-chain",
            contract: trackedContract,
            decimals: 0
        )

        _ = try await service.loadBalances(for: [target])
        _ = try await service.loadBalances(for: [target])

        #expect(await rpc.chainIDRequestCount == 1)
    }

    @Test
    func inventoryReturnsOnlyPinnedCustomFungibleTokens() async throws {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedHoldings(database)

        let targets = try await database
            .trackedEVMTokenBalanceTargets(walletID: walletID)

        let target = try #require(targets.first)
        #expect(targets.count == 1)
        #expect(target.holdingID == fixture.trackedHoldingID)
        #expect(target.networkID == "eth")
        #expect(target.expectedChainID == 1)
        #expect(target.ownerAddress == ownerAddress)
        #expect(target.contractAddress == trackedContract)
        #expect(target.decimals == 6)
    }

    @Test
    func historicalPriceCacheRejectsUnattributedValuesAndExpiredQuotes()
        async throws {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedHoldings(database)
        let observedAt = Date().timeIntervalSince1970 + 10

        try await database.saveAnkrHistoricalTokenPrices(
            [
                fixture.trackedHoldingID.assetID: Decimal(string: "3.5")!,
                "eth:not-owned": Decimal(string: "999")!
            ],
            walletID: walletID,
            now: observedAt
        )

        let cached = try await database.cachedAnkrHistoricalTokenPrices(
            walletID: walletID,
            now: observedAt
        )
        #expect(cached[fixture.trackedHoldingID.assetID] == 2)
        #expect(cached["eth:not-owned"] == nil)
        let expired = try await database.cachedAnkrHistoricalTokenPrices(
            walletID: walletID, now: observedAt + 301
        )
        #expect(expired.isEmpty)
    }

    @Test
    func failedDedicatedQueryPreservesTrackedHoldingDuringSnapshot()
        async throws {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedHoldings(database)
        let failedBatch = TrackedEVMTokenBalanceBatch(
            updates: [],
            failedHoldingIDs: [fixture.trackedHoldingID]
        )

        try await database.saveWalletSnapshot(
            emptyAuthoritativeSnapshot(),
            address: ownerAddress,
            trackedTokenBalances: failedBatch
        )

        let holdings = try await readHoldings(database, fixture: fixture)
        #expect(holdings.tracked?.balance == "7")
        #expect(holdings.tracked?.balanceAtomic == "7000000")
        #expect(holdings.tracked?.fiatUSDValue == "14")
        #expect(holdings.ordinary?.balance == "0")
        #expect(holdings.ordinary?.balanceAtomic == "0")
        #expect(holdings.ordinary?.fiatUSDValue == "0")
    }

    @Test
    func successfulDedicatedQueryReplacesTrackedBalanceExactly()
        async throws {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedHoldings(database)
        try await database.pool.write { database in
            try database.execute(
                sql: "UPDATE assetPrices SET expiresAt = 0"
            )
        }
        let update = TrackedEVMTokenBalanceUpdate(
            holdingID: fixture.trackedHoldingID,
            balanceText: "290.268219",
            balanceAtomic: "290268219"
        )

        try await database.saveWalletSnapshot(
            emptyAuthoritativeSnapshot(),
            address: ownerAddress,
            trackedTokenBalances: TrackedEVMTokenBalanceBatch(
                updates: [update],
                failedHoldingIDs: []
            )
        )

        let holdings = try await readHoldings(database, fixture: fixture)
        #expect(holdings.tracked?.balance == "290.268219")
        #expect(holdings.tracked?.balanceAtomic == "290268219")
        #expect(holdings.tracked?.fiatUSDValue == "580.536438")
    }

    @Test
    func successfulDedicatedZeroBalanceClearsTrackedHolding()
        async throws {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedHoldings(database)
        let update = TrackedEVMTokenBalanceUpdate(
            holdingID: fixture.trackedHoldingID,
            balanceText: "0",
            balanceAtomic: "0"
        )

        try await database.saveWalletSnapshot(
            emptyAuthoritativeSnapshot(),
            address: ownerAddress,
            trackedTokenBalances: TrackedEVMTokenBalanceBatch(
                updates: [update],
                failedHoldingIDs: []
            )
        )

        let holdings = try await readHoldings(database, fixture: fixture)
        #expect(holdings.tracked?.balance == "0")
        #expect(holdings.tracked?.balanceAtomic == "0")
        #expect(holdings.tracked?.fiatUSDValue == "0")
    }

    @Test
    func invalidTrackedUpdateRollsBackProviderHoldingReset()
        async throws {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedHoldings(database)
        let invalidUpdate = TrackedEVMTokenBalanceUpdate(
            holdingID: TrackedEVMTokenHoldingID(
                accountID: "unknown-account",
                assetID: fixture.trackedHoldingID.assetID
            ),
            balanceText: "1",
            balanceAtomic: "1000000"
        )

        await #expect(
            throws: WalletSnapshotPersistenceError
                .invalidTrackedTokenBalance
        ) {
            try await database.saveWalletSnapshot(
                emptyAuthoritativeSnapshot(),
                address: ownerAddress,
                trackedTokenBalances: TrackedEVMTokenBalanceBatch(
                    updates: [invalidUpdate],
                    failedHoldingIDs: []
                )
            )
        }

        let holdings = try await readHoldings(database, fixture: fixture)
        #expect(holdings.tracked?.balance == "7")
        #expect(holdings.ordinary?.balance == "5")
    }

    @Test
    func concurrentEVMRequestsRetainTheirOwnResponseIdentifiers()
        async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            ConcurrentEVMRPCURLProtocol.self
        ]
        let session = URLSession(configuration: configuration)
        let client = try SendEVMRPCClient(
            networkID: "eth",
            session: session
        )

        async let chainID = client.chainID()
        async let nativeBalance = client.nativeBalance(
            address: ownerAddress
        )
        let values = try await (chainID, nativeBalance)

        #expect(values.0 == "0x1")
        #expect(values.1 == "0x2")
    }

    @Test
    func transientJSONRPCServerFailureFallsBackToNextEndpoint()
        async throws {
        EVMServerFailureFallbackURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            EVMServerFailureFallbackURLProtocol.self
        ]
        let session = URLSession(configuration: configuration)
        let suffix = UUID().uuidString.lowercased()
        let first = try #require(
            URL(string: "https://internal-error-\(suffix).invalid")
        )
        let second = try #require(
            URL(string: "https://healthy-\(suffix).invalid")
        )
        let client = try SendEVMRPCClient(
            networkID: "eth",
            session: session,
            endpoints: [first, second]
        )

        let value = try await client.nativeBalance(address: ownerAddress)

        #expect(value == "0x2a")
        #expect(
            EVMServerFailureFallbackURLProtocol.requestCount == 2
        )
    }

    @Test
    func providerCapacityJSONRPCFailureFallsBackToNextEndpoint()
        async throws {
        EVMServerFailureFallbackURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            EVMServerFailureFallbackURLProtocol.self
        ]
        let session = URLSession(configuration: configuration)
        let suffix = UUID().uuidString.lowercased()
        let first = try #require(
            URL(string: "https://provider-timeout-\(suffix).invalid")
        )
        let second = try #require(
            URL(string: "https://healthy-\(suffix).invalid")
        )
        let client = try SendEVMRPCClient(
            networkID: "eth",
            session: session,
            endpoints: [first, second]
        )

        let value = try await client.nativeBalance(address: ownerAddress)

        #expect(value == "0x2a")
        #expect(
            EVMServerFailureFallbackURLProtocol.requestCount == 2
        )
    }

    @Test
    func cannotFulfillJSONRPCFailureFallsBackToNextEndpoint()
        async throws {
        EVMServerFailureFallbackURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            EVMServerFailureFallbackURLProtocol.self
        ]
        let session = URLSession(configuration: configuration)
        let suffix = UUID().uuidString.lowercased()
        let first = try #require(
            URL(string: "https://cannot-fulfill-\(suffix).invalid")
        )
        let second = try #require(
            URL(string: "https://healthy-\(suffix).invalid")
        )
        let client = try SendEVMRPCClient(
            networkID: "eth",
            session: session,
            endpoints: [first, second]
        )

        let value = try await client.nativeBalance(address: ownerAddress)

        #expect(value == "0x2a")
        #expect(
            EVMServerFailureFallbackURLProtocol.requestCount == 2
        )
    }

    private func target(
        assetID: String,
        contract: String,
        decimals: Int
    ) -> TrackedEVMTokenBalanceTarget {
        TrackedEVMTokenBalanceTarget(
            holdingID: TrackedEVMTokenHoldingID(
                accountID: accountID,
                assetID: assetID
            ),
            networkID: "eth",
            expectedChainID: 1,
            ownerAddress: ownerAddress,
            contractAddress: contract,
            decimals: decimals
        )
    }

    private func emptyAuthoritativeSnapshot() -> WalletHomeSnapshot {
        WalletHomeSnapshot(
            totalBalance: 0,
            assets: [],
            transactions: [],
            evmBalanceAuthority: EVMBalanceSnapshotAuthority(
                providerAssetCount: 0,
                mappedAssetCount: 0,
                unavailableFiatAssetCount: 0,
                hasMorePages: false
            )
        )
    }

    private func seedHoldings(
        _ database: WalletDatabase
    ) async throws -> TrackedTokenFixture {
        let trackedAssetID = "eth:\(trackedContract)"
        let ordinaryAssetID = "eth:\(ordinaryContract)"
        try await database.pool.write { db in
            let now = Date().timeIntervalSince1970
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Tracked Token Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: "opaque-keychain-reference",
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil
            ).insert(db)
            try DBWalletAccountRecord(
                id: accountID,
                walletID: walletID,
                networkID: "eth",
                address: ownerAddress,
                normalizedAddress: ownerAddress,
                label: nil,
                derivationPath: nil,
                accountIndex: 0,
                publicKey: nil,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(db)
            try insertAsset(
                id: trackedAssetID,
                contract: trackedContract,
                now: now,
                database: db
            )
            try insertAsset(
                id: ordinaryAssetID,
                contract: ordinaryContract,
                now: now,
                database: db
            )
            try DBAccountAssetRecord(
                accountID: accountID,
                assetID: trackedAssetID,
                balance: "7",
                balanceAtomic: "7000000",
                fiatUSDValue: "14",
                isEnabled: true,
                isPinned: true,
                isHidden: false,
                sortOrder: 0,
                firstSeenAt: now,
                lastSeenAt: now,
                updatedAt: now
            ).insert(db)
            try DBAccountAssetRecord(
                accountID: accountID,
                assetID: ordinaryAssetID,
                balance: "5",
                balanceAtomic: "5000000",
                fiatUSDValue: "10",
                isEnabled: true,
                isPinned: false,
                isHidden: false,
                sortOrder: 1,
                firstSeenAt: now,
                lastSeenAt: now,
                updatedAt: now
            ).insert(db)
            try DBAssetPriceRecord(
                assetID: trackedAssetID,
                quoteCurrency: "USD",
                price: "2",
                provider: AssetPriceClient.dexScreenerContractPriceProvider,
                observedAt: now,
                expiresAt: now + 3_600
            ).insert(db)
        }
        return TrackedTokenFixture(
            trackedHoldingID: TrackedEVMTokenHoldingID(
                accountID: accountID,
                assetID: trackedAssetID
            ),
            ordinaryHoldingID: TrackedEVMTokenHoldingID(
                accountID: accountID,
                assetID: ordinaryAssetID
            )
        )
    }

    private func insertAsset(
        id: String,
        contract: String,
        now: Double,
        database: Database
    ) throws {
        try DBAssetRecord(
            id: id,
            networkID: "eth",
            assetType: DatabaseAssetType.fungibleToken.rawValue,
            contractAddress: contract,
            normalizedContractAddress: contract,
            name: "Tracked Token",
            symbol: "TRACK",
            decimals: 6,
            trustWalletBlockchain: "ethereum",
            trustWalletContractAddress: contract,
            isVerified: true,
            isSpam: false,
            createdAt: now,
            updatedAt: now,
            metadataUpdatedAt: now
        ).insert(database)
    }

    private func readHoldings(
        _ database: WalletDatabase,
        fixture: TrackedTokenFixture
    ) async throws -> (
        tracked: DBAccountAssetRecord?,
        ordinary: DBAccountAssetRecord?
    ) {
        try await database.pool.read { db in
            (
                try DBAccountAssetRecord.fetchOne(
                    db,
                    key: [
                        "accountID": fixture.trackedHoldingID.accountID,
                        "assetID": fixture.trackedHoldingID.assetID
                    ]
                ),
                try DBAccountAssetRecord.fetchOne(
                    db,
                    key: [
                        "accountID": fixture.ordinaryHoldingID.accountID,
                        "assetID": fixture.ordinaryHoldingID.assetID
                    ]
                )
            )
        }
    }
}

private struct TrackedTokenFixture {
    let trackedHoldingID: TrackedEVMTokenHoldingID
    let ordinaryHoldingID: TrackedEVMTokenHoldingID
}

private enum TrackedTokenRPCStubError: Error {
    case unavailable
}

private actor TrackedTokenRPCStub: TrackedEVMTokenBalanceRPC {
    let chainIDHex: String
    let balancesByContract: [String: String]
    let failedContracts: Set<String>
    private(set) var chainIDRequestCount = 0

    init(
        chainIDHex: String,
        balancesByContract: [String: String],
        failedContracts: Set<String>
    ) {
        self.chainIDHex = chainIDHex
        self.balancesByContract = Dictionary(
            uniqueKeysWithValues: balancesByContract.map {
                ($0.key.lowercased(), $0.value)
            }
        )
        self.failedContracts = Set(
            failedContracts.map { $0.lowercased() }
        )
    }

    func chainID() async throws -> String {
        chainIDRequestCount += 1
        return chainIDHex
    }

    func tokenBalance(
        ownerAddress _: String,
        contractAddress: String
    ) async throws -> String {
        let normalized = contractAddress.lowercased()
        guard !failedContracts.contains(normalized),
              let balance = balancesByContract[normalized]
        else {
            throw TrackedTokenRPCStubError.unavailable
        }
        return try abiWord(balance)
    }
}

private actor TransientTrackedTokenRPCStub:
    TrackedEVMTokenBalanceRPC {
    let balancesByContract: [String: String]
    let initiallyFailedContracts: Set<String>
    private var requestCounts: [String: Int] = [:]

    init(
        balancesByContract: [String: String],
        initiallyFailedContracts: Set<String>
    ) {
        self.balancesByContract = Dictionary(
            uniqueKeysWithValues: balancesByContract.map {
                ($0.key.lowercased(), $0.value)
            }
        )
        self.initiallyFailedContracts = Set(
            initiallyFailedContracts.map { $0.lowercased() }
        )
    }

    func chainID() async throws -> String { "0x1" }

    func tokenBalance(
        ownerAddress _: String,
        contractAddress: String
    ) async throws -> String {
        let normalized = contractAddress.lowercased()
        requestCounts[normalized, default: 0] += 1
        if initiallyFailedContracts.contains(normalized),
           requestCounts[normalized] == 1 {
            throw TrackedTokenRPCStubError.unavailable
        }
        guard let balance = balancesByContract[normalized] else {
            throw TrackedTokenRPCStubError.unavailable
        }
        return try abiWord(balance)
    }

    func requestCount(for contractAddress: String) -> Int {
        requestCounts[contractAddress.lowercased(), default: 0]
    }
}

private actor RepeatedTransientTrackedTokenRPCStub:
    TrackedEVMTokenBalanceRPC {
    let balancesByContract: [String: String]
    let failureAttemptsByContract: [String: Int]
    private var requestCounts: [String: Int] = [:]

    init(
        balancesByContract: [String: String],
        failureAttemptsByContract: [String: Int]
    ) {
        self.balancesByContract = Dictionary(
            uniqueKeysWithValues: balancesByContract.map {
                ($0.key.lowercased(), $0.value)
            }
        )
        self.failureAttemptsByContract = Dictionary(
            uniqueKeysWithValues: failureAttemptsByContract.map {
                ($0.key.lowercased(), $0.value)
            }
        )
    }

    func chainID() async throws -> String { "0x1" }

    func tokenBalance(
        ownerAddress _: String,
        contractAddress: String
    ) async throws -> String {
        let normalized = contractAddress.lowercased()
        requestCounts[normalized, default: 0] += 1
        if requestCounts[normalized, default: 0]
            <= failureAttemptsByContract[normalized, default: 0] {
            throw TrackedTokenRPCStubError.unavailable
        }
        guard let balance = balancesByContract[normalized] else {
            throw TrackedTokenRPCStubError.unavailable
        }
        return try abiWord(balance)
    }

    func requestCount(for contractAddress: String) -> Int {
        requestCounts[contractAddress.lowercased(), default: 0]
    }
}

private func abiWord(_ quantity: String) throws -> String {
    guard quantity.hasPrefix("0x") else {
        throw TrackedTokenRPCStubError.unavailable
    }
    let digits = String(quantity.dropFirst(2))
    guard !digits.isEmpty,
          digits.count <= 64,
          digits.allSatisfy(\.isHexDigit)
    else {
        throw TrackedTokenRPCStubError.unavailable
    }
    return "0x" + String(repeating: "0", count: 64 - digits.count)
        + digits
}

private final class ConcurrentEVMRPCURLProtocol:
    URLProtocol,
    @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let body = request.httpBody
                ?? Self.readBodyStream(request.httpBodyStream),
            let object = try? JSONSerialization.jsonObject(with: body)
                as? [String: Any],
            let identifier = object["id"] as? Int,
            let method = object["method"] as? String,
            let url = request.url
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.cannotParseResponse)
            )
            return
        }
        let result = method == "eth_chainId" ? "0x1" : "0x2"
        let delay = method == "eth_chainId" ? 0.08 : 0

        DispatchQueue.global().asyncAfter(
            deadline: .now() + delay
        ) { [self] in
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json"
                ]
            )!
            let responseBody = try! JSONSerialization.data(
                withJSONObject: [
                    "jsonrpc": "2.0",
                    "id": identifier,
                    "result": result
                ]
            )
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: responseBody)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(
                &buffer,
                maxLength: buffer.count
            )
            guard count >= 0 else { return nil }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}

private final class EVMServerFailureFallbackURLProtocol:
    URLProtocol,
    @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static func reset() {
        lock.withLock { count = 0 }
    }

    static var requestCount: Int {
        lock.withLock { count }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let body = request.httpBody
                ?? Self.readBodyStream(request.httpBodyStream),
              let object = try? JSONSerialization.jsonObject(with: body)
                as? [String: Any],
              let identifier = object["id"] as? Int
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.cannotParseResponse)
            )
            return
        }
        Self.lock.withLock { Self.count += 1 }
        let isInternalError = url.host?.hasPrefix("internal-error-") == true
        let isProviderTimeout = url.host?.hasPrefix("provider-timeout-")
            == true
        let cannotFulfill = url.host?.hasPrefix("cannot-fulfill-")
            == true
        let payload: [String: Any] = if isInternalError {
            [
                "jsonrpc": "2.0",
                "id": identifier,
                "error": [
                    "code": -32603,
                    "message": "Internal error"
                ]
            ]
        } else if isProviderTimeout {
            [
                "jsonrpc": "2.0",
                "id": identifier,
                "error": [
                    "code": 30,
                    "message": "Request timeout on the free plan"
                ]
            ]
        } else if cannotFulfill {
            [
                "jsonrpc": "2.0",
                "id": identifier,
                "error": [
                    "code": -32_046,
                    "message": "Cannot fulfill request"
                ]
            ]
        } else {
            [
                "jsonrpc": "2.0",
                "id": identifier,
                "result": "0x2a"
            ]
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let responseBody = try! JSONSerialization.data(
            withJSONObject: payload
        )
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}
