import Foundation

actor SolanaAPIClient {
    static let shared = SolanaAPIClient()

    private let transport: SolanaRPCTransport

    init(transport: SolanaRPCTransport = .shared) {
        self.transport = transport
    }

    func loadSnapshot(
        accounts: SolanaAccountSet,
        historyCursors: [String: SolanaHistoryCursor],
        operationID: UUID = UUID()
    ) async throws -> SolanaWalletSnapshot {
        let balanceSnapshot = try await loadBalanceSnapshot(
            accounts: accounts,
            historyCursors: historyCursors
        )
        return try await loadSnapshot(
            accounts: accounts,
            addressSnapshots: balanceSnapshot.addressSnapshots,
            historyCursors: historyCursors,
            operationID: operationID
        )
    }

    func loadBalanceSnapshot(
        accounts: SolanaAccountSet,
        historyCursors: [String: SolanaHistoryCursor]
    ) async throws -> SolanaWalletSnapshot {
        let materials = accounts.all
        let requests = materials.enumerated().flatMap { index, material in
            Self.balanceRequests(
                material: material,
                idOffset: index * 3
            )
        }
        let responses = try await transport.batchBalance(requests)
        guard responses.count == requests.count,
              responses.allSatisfy({ $0.id != nil }),
              Set(responses.compactMap(\.id)) == Set(requests.map(\.id))
        else {
            throw SolanaProviderError.incompleteBalanceBatch(
                expected: requests.count,
                actual: responses.count
            )
        }
        let addressSnapshots = try materials.enumerated().map {
            index, material in
            try Self.makeBalanceSnapshot(
                material: material,
                responses: Self.normalizedBalanceResponses(
                    responses,
                    idOffset: index * 3
                )
            )
        }

        return try SolanaWalletSnapshot(
            accounts: accounts,
            addressSnapshots: addressSnapshots,
            history: [],
            historyCursors: Array(historyCursors.values)
        )
    }

    func loadSnapshot(
        accounts: SolanaAccountSet,
        addressSnapshots: [SolanaAddressSnapshot],
        historyCursors: [String: SolanaHistoryCursor],
        operationID: UUID = UUID()
    ) async throws -> SolanaWalletSnapshot {
        var historyAddressKinds: [String: SolanaDerivationKind] = [:]
        for snapshot in addressSnapshots {
            historyAddressKinds[snapshot.material.address] =
                snapshot.material.kind
        }
        let historyResult = try await loadHistory(
            ownerAddresses: Set(accounts.all.map(\.address)),
            queriedAddressKinds: historyAddressKinds,
            existingCursors: historyCursors,
            operationID: operationID
        )

        let snapshot = try SolanaWalletSnapshot(
            accounts: accounts,
            addressSnapshots: addressSnapshots,
            history: historyResult.items.sorted {
                ($0.timestamp ?? 0) > ($1.timestamp ?? 0)
            },
            historyCursors: historyResult.cursors
        )
        return snapshot
    }

    private static func balanceRequests(
        material: SolanaAccountMaterial,
        idOffset: Int
    ) -> [SolanaRPCRequest] {
        let accountConfig: SolanaJSONValue = .object([
            "encoding": .string("jsonParsed"),
            // A processed account state includes provider-observed pending
            // balance changes instead of waiting for confirmation.
            "commitment": .string("processed")
        ])
        return [
            SolanaRPCRequest(
                method: "getBalance",
                params: [
                    .string(material.address),
                    .object(["commitment": .string("processed")])
                ],
                id: idOffset + 1
            ),
            SolanaRPCRequest(
                method: "getTokenAccountsByOwner",
                params: [
                    .string(material.address),
                    .object([
                        "programId": .string(SolanaConstants.tokenProgramID)
                    ]),
                    accountConfig
                ],
                id: idOffset + 2
            ),
            SolanaRPCRequest(
                method: "getTokenAccountsByOwner",
                params: [
                    .string(material.address),
                    .object([
                        "programId": .string(SolanaConstants.token2022ProgramID)
                    ]),
                    accountConfig
                ],
                id: idOffset + 3
            )
        ]
    }

    private static func normalizedBalanceResponses(
        _ responses: [SolanaRPCResponse],
        idOffset: Int
    ) -> [SolanaRPCResponse] {
        responses.compactMap { response in
            guard let id = response.id,
                  (idOffset + 1...idOffset + 3).contains(id) else {
                return nil
            }
            return SolanaRPCResponse(
                result: response.result,
                error: response.error,
                id: id - idOffset
            )
        }
    }

    static func makeBalanceSnapshot(
        material: SolanaAccountMaterial,
        responses: [SolanaRPCResponse]
    ) throws -> SolanaAddressSnapshot {
        let expectedIDs = Set([1, 2, 3])
        do {
            guard responses.count == expectedIDs.count else {
                throw SolanaProviderError.incompleteBalanceBatch(
                    expected: expectedIDs.count,
                    actual: responses.count
                )
            }
            var byID: [Int: SolanaRPCResponse] = [:]
            for response in responses {
                guard
                    let responseID = response.id,
                    expectedIDs.contains(responseID)
                else {
                    throw SolanaProviderError
                        .unexpectedBalanceBatchResponse
                }
                guard byID[responseID] == nil else {
                    throw SolanaProviderError
                        .duplicateBalanceBatchResponse(
                            responseID: responseID
                        )
                }
                guard response.error == nil else {
                    throw SolanaProviderError
                        .invalidBalanceBatchResponse(
                            responseID: responseID,
                            field: "rpc_error"
                        )
                }
                byID[responseID] = response
            }
            guard Set(byID.keys) == expectedIDs else {
                throw SolanaProviderError.incompleteBalanceBatch(
                    expected: expectedIDs.count,
                    actual: byID.count
                )
            }

            let lamports = try balanceLamports(response: byID[1])
            var tokenAccounts: [(
                responseID: Int,
                values: [SolanaJSONValue]
            )] = []
            for responseID in [2, 3] {
                tokenAccounts.append(
                    (
                        responseID,
                        try tokenAccountValues(
                            response: byID[responseID],
                            responseID: responseID
                        )
                    )
                )
            }
            let tokens = try parseTokenAccounts(tokenAccounts)
            let authority = SolanaBalanceBatchAuthority(
                receivedResponseCount: byID.count,
                tokenProgramResponseCount: tokenAccounts.count
            )
            return SolanaAddressSnapshot(
                material: material,
                solBalance: Decimal(lamports)
                    / SolanaConstants.lamportsPerSOL,
                solAtomicBalance: String(lamports),
                tokenBalances: tokens,
                balanceAuthority: authority
            )
        } catch {
            throw error
        }
    }

    private static func balanceLamports(
        response: SolanaRPCResponse?
    ) throws -> UInt64 {
        guard let response else {
            throw SolanaProviderError.incompleteBalanceBatch(
                expected: SolanaBalanceBatchAuthority.expectedResponseCount,
                actual: 0
            )
        }
        guard let result = response.result else {
            throw SolanaProviderError.invalidBalanceBatchResponse(
                responseID: 1,
                field: "result_missing"
            )
        }
        guard case let .object(object) = result else {
            throw SolanaProviderError.invalidBalanceBatchResponse(
                responseID: 1,
                field: "result_not_object"
            )
        }
        guard
            let value = object["value"],
            let lamports = exactUInt64(value)
        else {
            throw SolanaProviderError.invalidBalanceBatchResponse(
                responseID: 1,
                field: "value_not_uint64"
            )
        }
        return lamports
    }

    private static func tokenAccountValues(
        response: SolanaRPCResponse?,
        responseID: Int
    ) throws -> [SolanaJSONValue] {
        guard let response else {
            throw SolanaProviderError.incompleteBalanceBatch(
                expected: SolanaBalanceBatchAuthority.expectedResponseCount,
                actual: 0
            )
        }
        guard let result = response.result else {
            throw SolanaProviderError.invalidBalanceBatchResponse(
                responseID: responseID,
                field: "result_missing"
            )
        }
        guard case let .object(object) = result else {
            throw SolanaProviderError.invalidBalanceBatchResponse(
                responseID: responseID,
                field: "result_not_object"
            )
        }
        guard let value = object["value"] else {
            throw SolanaProviderError.invalidBalanceBatchResponse(
                responseID: responseID,
                field: "value_missing"
            )
        }
        guard case let .array(accounts) = value else {
            throw SolanaProviderError.invalidBalanceBatchResponse(
                responseID: responseID,
                field: "value_not_array"
            )
        }
        return accounts
    }

    private static func parseTokenAccounts(
        _ batches: [(responseID: Int, values: [SolanaJSONValue])]
    ) throws -> [SolanaTokenBalance] {
        struct Aggregate {
            var addresses: [String]
            var atomicAmount: UInt64
            let decimals: Int
        }
        var byMint: [String: Aggregate] = [:]
        var seenTokenAccounts = Set<String>()
        for batch in batches {
            for (itemIndex, account) in batch.values.enumerated() {
                guard
                    let object = account.object,
                    let address = nonempty(object["pubkey"]?.string),
                    seenTokenAccounts.insert(address).inserted,
                    let info = object["account"]?.object?["data"]?
                        .object?["parsed"]?.object?["info"]?.object,
                    let mint = nonempty(info["mint"]?.string),
                    let tokenAmount = info["tokenAmount"]?.object,
                    let raw = tokenAmount["amount"]?.string,
                    let canonicalRaw =
                        ExactDecimalText.canonicalUnsignedInteger(raw),
                    let atomicAmount = UInt64(canonicalRaw),
                    let decimalsValue = tokenAmount["decimals"],
                    let decimals = exactInt(
                        decimalsValue,
                        allowedRange: 0...255
                    )
                else {
                    throw SolanaProviderError
                        .invalidBalanceBatchResponse(
                            responseID: batch.responseID,
                            field: "token_account_\(itemIndex)"
                        )
                }
                if let current = byMint[mint] {
                    guard current.decimals == decimals else {
                        throw SolanaProviderError
                            .invalidBalanceBatchResponse(
                                responseID: batch.responseID,
                                field: "token_decimals_\(itemIndex)"
                            )
                    }
                    let (sum, overflow) = current.atomicAmount
                        .addingReportingOverflow(atomicAmount)
                    guard !overflow else {
                        throw SolanaProviderError.tokenBalanceOverflow(
                            responseID: batch.responseID,
                            itemIndex: itemIndex
                        )
                    }
                    byMint[mint] = Aggregate(
                        addresses: current.addresses + [address],
                        atomicAmount: sum,
                        decimals: decimals
                    )
                } else {
                    byMint[mint] = Aggregate(
                        addresses: [address],
                        atomicAmount: atomicAmount,
                        decimals: decimals
                    )
                }
            }
        }
        return byMint.map { mint, aggregate in
            let metadata = SolanaTokenCatalog.byMint[mint]
            let atomicText = String(aggregate.atomicAmount)
            return SolanaTokenBalance(
                mint: mint,
                tokenAccountAddresses: aggregate.addresses,
                name: metadata?.name
                    ?? SolanaTransactionMapper.shortMint(mint),
                symbol: metadata?.symbol
                    ?? SolanaTransactionMapper.shortMint(mint),
                decimals: aggregate.decimals,
                amount: Decimal(aggregate.atomicAmount)
                    / SolanaTransactionMapper.power10(aggregate.decimals),
                atomicAmount: atomicText,
                catalogRank: metadata?.rank
            )
        }.sorted { $0.mint < $1.mint }
    }

    private static func exactUInt64(
        _ value: SolanaJSONValue
    ) -> UInt64? {
        guard case let .number(decimal) = value, decimal >= 0 else {
            return nil
        }
        let text = NSDecimalNumber(decimal: decimal).stringValue
        guard
            let canonical = ExactDecimalText.canonicalUnsignedInteger(text),
            let integer = UInt64(canonical),
            Decimal(integer) == decimal
        else {
            return nil
        }
        return integer
    }

    private static func exactInt(
        _ value: SolanaJSONValue?,
        allowedRange: ClosedRange<Int>
    ) -> Int? {
        guard
            let value,
            let integer = exactUInt64(value),
            integer <= UInt64(Int.max)
        else {
            return nil
        }
        let result = Int(integer)
        return allowedRange.contains(result) ? result : nil
    }

    private static func nonempty(_ value: String?) -> String? {
        guard
            let value,
            !value.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            return nil
        }
        return value
    }

    private func loadHistory(
        ownerAddresses: Set<String>,
        queriedAddressKinds: [String: SolanaDerivationKind],
        existingCursors: [String: SolanaHistoryCursor],
        operationID: UUID
    ) async throws -> (
        items: [SolanaHistoryItem],
        cursors: [SolanaHistoryCursor]
    ) {
        var signaturesByValue: [String: SolanaSignatureInfo] = [:]
        var updatedCursors: [SolanaHistoryCursor] = []
        let inputs = queriedAddressKinds.sorted { $0.key < $1.key }
        let discoveries = try await withThrowingTaskGroup(
            of: (
                String,
                SolanaDerivationKind,
                SolanaHistoryCursor?,
                [SolanaSignatureInfo]
            ).self
        ) { group in
            for (address, ownerKind) in inputs {
                let existing = existingCursors[address]
                group.addTask {
                    let loaded = try await self.signatures(
                        address: address,
                        until: existing?.newestSignature,
                        operationID: operationID
                    )
                    return (address, ownerKind, existing, loaded)
                }
            }
            var loaded: [(
                String,
                SolanaDerivationKind,
                SolanaHistoryCursor?,
                [SolanaSignatureInfo]
            )] = []
            for try await discovery in group {
                loaded.append(discovery)
            }
            return loaded.sorted { $0.0 < $1.0 }
        }
        for (address, ownerKind, existing, loaded) in discoveries {
            for info in loaded {
                signaturesByValue[info.signature] = info
            }
            updatedCursors.append(
                SolanaHistoryCursor(
                    queriedAddress: address,
                    ownerKind: ownerKind,
                    newestSignature: loaded.first?.signature
                        ?? existing?.newestSignature,
                    oldestSignature: existing?.oldestSignature
                        ?? loaded.last?.signature,
                    providerHistoryComplete: false
                )
            )
        }
        let signatures = signaturesByValue.values.sorted {
            ($0.blockTime ?? 0) > ($1.blockTime ?? 0)
        }
        var result: [SolanaHistoryItem] = []
        for start in stride(from: 0, to: signatures.count, by: 50) {
            let chunk = Array(
                signatures[start..<min(start + 50, signatures.count)]
            )
            let requests = chunk.enumerated().map { index, info in
                SolanaRPCRequest(
                    method: "getTransaction",
                    params: [
                        .string(info.signature),
                        .object([
                            "encoding": .string("jsonParsed"),
                            "commitment": .string("confirmed"),
                            "maxSupportedTransactionVersion": .number(0)
                        ])
                    ],
                    id: index + 1
                )
            }
            let responses = try await transport.batch(requests)
            let responseByID: [Int: SolanaJSONValue] = Dictionary(
                uniqueKeysWithValues: responses.compactMap { response in
                    guard let id = response.id, let result = response.result else {
                        return nil
                    }
                    return (id, result)
                }
            )
            for (index, info) in chunk.enumerated() {
                guard let transaction = responseByID[index + 1] else {
                    continue
                }
                for owner in ownerAddresses {
                    result += SolanaTransactionMapper.history(
                        response: transaction,
                        signatureInfo: info,
                        ownerAddress: owner
                    )
                }
            }
        }
        return (deduplicated(result), updatedCursors)
    }

    private func signatures(
        address: String,
        until: String?,
        operationID: UUID
    ) async throws -> [SolanaSignatureInfo] {
        let transport = self.transport
        let result = try await Self.collectSignatures(
            until: until,
            operationID: operationID,
            pageLimit: 100,
            maximumPages: 5,
            maximumItems: 100
        ) { before, until, pageLimit in
            var configuration: [String: SolanaJSONValue] = [
                "limit": .number(Decimal(pageLimit)),
                "commitment": .string("confirmed")
            ]
            if let before {
                configuration["before"] = .string(before)
            }
            if let until {
                configuration["until"] = .string(until)
            }
            return try await transport.call(
                method: "getSignaturesForAddress",
                params: [
                    .string(address),
                    .object(configuration)
                ]
            )
        }
        return result
    }

    static func collectSignatures(
        until: String?,
        operationID: UUID = UUID(),
        pageLimit: Int = 1_000,
        maximumPages: Int = 100,
        maximumItems: Int? = nil,
        fetchPage: @escaping @Sendable (
            _ before: String?,
            _ until: String?,
            _ pageLimit: Int
        ) async throws -> SolanaJSONValue
    ) async throws -> [SolanaSignatureInfo] {
        guard pageLimit > 0 else {
            throw HistoryPaginationError.invalidPageLimit
        }
        let pagination: HistoryPaginationResult<SolanaSignatureInfo> =
            try await HistoryPaginator.collect(
                service: "SOLANA",
                stream: "signatures",
                initialCursor: Optional<String>.none,
                maximumPages: maximumPages,
                maximumItems: maximumItems
            ) { before in
                let response = try await fetchPage(
                    before,
                    until,
                    pageLimit
                )
                guard let rawPage = response.array else {
                    throw SolanaProviderError.malformedResponse(
                        method: "getSignaturesForAddress"
                    )
                }
                let decodedPage = rawPage.compactMap {
                    signatureInfo($0)
                }
                let nextCursor = try signatureCursor(
                    rawPage: rawPage,
                    pageLimit: pageLimit
                )
                return HistoryPage(
                    items: decodedPage,
                    nextCursor: nextCursor,
                    reportedItemCount: rawPage.count
                )
            }
        return pagination.items
    }

    private static func signatureCursor(
        rawPage: [SolanaJSONValue],
        pageLimit: Int
    ) throws -> String? {
        guard rawPage.count == pageLimit else {
            return nil
        }
        guard
            let signature = rawPage.last?.object?["signature"]?.string,
            !signature.isEmpty
        else {
            throw SolanaProviderError.malformedResponse(
                method: "getSignaturesForAddress.paginationCursor"
            )
        }
        return signature
    }

    private static func signatureInfo(
        _ value: SolanaJSONValue
    ) -> SolanaSignatureInfo? {
        guard
            let object = value.object,
            let signature = object["signature"]?.string,
            let slot = object["slot"]?.int64
        else {
            return nil
        }
        return SolanaSignatureInfo(
            signature: signature,
            slot: slot,
            blockTime: object["blockTime"]?.decimal.map {
                NSDecimalNumber(decimal: $0).doubleValue
            },
            failed: {
                guard let error = object["err"] else { return false }
                if case .null = error { return false }
                return true
            }()
        )
    }

    private func deduplicated(
        _ items: [SolanaHistoryItem]
    ) -> [SolanaHistoryItem] {
        var seen = Set<String>()
        return items.filter {
            let identity = "\($0.signature):\($0.mint ?? "native")"
            return seen.insert(identity).inserted
        }
    }
}
