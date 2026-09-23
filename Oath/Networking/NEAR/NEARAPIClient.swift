import Foundation
import WalletCore

actor NEARAPIClient {
    static let shared = NEARAPIClient()

    let transport: NEARJSONRPCTransport?
    private let fastAPITransport: NEARFastAPITransport
    private let nearBlocksHistoryClient: NEARNearBlocksHistoryClient
    private let historyProviderRouter: NEARHistoryProviderRouter
    private var metadataCache: [String: NEARTokenMetadata] = [:]

    init(
        transport: NEARJSONRPCTransport? = nil,
        session: URLSession? = nil,
        historyRouter: AdaptiveProviderRouter = .shared
    ) {
        self.transport = transport ?? (try? NEARJSONRPCTransport())
        fastAPITransport = NEARFastAPITransport(session: session)
        nearBlocksHistoryClient = NEARNearBlocksHistoryClient(session: session)
        historyProviderRouter = NEARHistoryProviderRouter(
            router: historyRouter
        )
    }

    func loadSnapshot(
        material: NEARAccountMaterial,
        onBalances:
            (@Sendable (NEARWalletSnapshot) async throws -> Void)? = nil
    ) async throws -> NEARWalletSnapshot {
        guard NEARAddress.isValid(material.address) else {
            throw NEARProviderError.invalidAddress
        }
        let balanceLoad = try await loadBalances(
            address: material.address
        ) { nativeAtomic in
            guard let onBalances else { return }
            let nativeBalance = NEARAssetBalance(
                metadata: nil,
                amountText: try Self.userUnits(
                    atomic: nativeAtomic,
                    decimals: NEARConstants.decimals
                ),
                atomicAmount: nativeAtomic
            )
            try await onBalances(
                NEARWalletSnapshot(
                    material: material,
                    balances: [nativeBalance],
                    history: [],
                    balancesAreAuthoritative: false,
                    historyIsAuthoritative: false,
                    providerFailureCodes: [],
                    successfulBalanceAssetIDs: [
                        NEARConstants.nativeAssetID
                    ]
                )
            )
        }
        let partial = NEARWalletSnapshot(
            material: material,
            balances: balanceLoad.balances,
            history: [],
            balancesAreAuthoritative: balanceLoad.isAuthoritative,
            historyIsAuthoritative: false,
            providerFailureCodes: balanceLoad.failureCodes,
            successfulBalanceAssetIDs:
                balanceLoad.successfulAssetIDs
        )
        try await onBalances?(partial)
        try Task.checkCancellation()
        do {
            let history = try await history(address: material.address)
            return NEARWalletSnapshot(
                material: material,
                balances: balanceLoad.balances,
                history: history,
                balancesAreAuthoritative: balanceLoad.isAuthoritative,
                historyIsAuthoritative: true,
                providerFailureCodes: balanceLoad.failureCodes,
                successfulBalanceAssetIDs:
                    balanceLoad.successfulAssetIDs
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return NEARWalletSnapshot(
                material: material,
                balances: balanceLoad.balances,
                history: [],
                balancesAreAuthoritative: balanceLoad.isAuthoritative,
                historyIsAuthoritative: false,
                providerFailureCodes: balanceLoad.failureCodes
                    + [Self.failureCode(error)],
                successfulBalanceAssetIDs:
                    balanceLoad.successfulAssetIDs
            )
        }
    }

    func accessKeyState(
        accountID: String,
        publicKey: String
    ) async throws -> NEARAccessKeyState {
        guard NEARAddress.isValid(accountID), let transport else {
            throw NEARProviderError.invalidAddress
        }
        let result = try await transport.request(
            method: "query",
            parameters: .object([
                "request_type": .string("view_access_key"),
                "finality": .string("final"),
                "account_id": .string(accountID),
                "public_key": .string(publicKey)
            ])
        )
        guard let object = result.objectValue,
              let nonceText = object["nonce"]?.stringValue,
              let nonce = UInt64(nonceText),
              let blockHash = object["block_hash"]?.stringValue,
              let blockData = Base58.decodeNoCheck(string: blockHash),
              blockData.count == 32,
              let permission = object["permission"]
        else { throw NEARProviderError.invalidResponse("access_key") }
        return NEARAccessKeyState(
            nonce: nonce,
            blockHash: blockData,
            isFullAccess: permission.stringValue == "FullAccess"
        )
    }

    func submit(signedTransaction: Data) async throws -> NEARSubmitResult {
        guard !signedTransaction.isEmpty, let transport else {
            throw NEARProviderError.missingConfiguration
        }
        let result = try await transport.request(
            method: "send_tx",
            parameters: .object([
                "signed_tx_base64": .string(
                    signedTransaction.base64EncodedString()
                ),
                "wait_until": .string("EXECUTED")
            ])
        )
        guard let object = result.objectValue,
              let transaction = object["transaction"]?.objectValue,
              let hash = transaction["hash"]?.stringValue
        else { throw NEARProviderError.invalidResponse("broadcast") }
        guard let status = object["status"]?.objectValue else {
            throw NEARProviderError.invalidResponse("broadcast_status")
        }
        let succeeded = status["SuccessValue"] != nil
            || status["SuccessReceiptId"] != nil
        let providerStatus: String
        if succeeded {
            providerStatus = "success"
        } else if let failure = status["Failure"] {
            providerStatus = NEARErrorCode.executionFailure(failure)
        } else {
            throw NEARProviderError.invalidResponse("broadcast_status")
        }
        return NEARSubmitResult(
            transactionHash: hash,
            succeeded: succeeded,
            providerStatus: providerStatus
        )
    }

    func fungibleTokenBalance(
        contractID: String,
        accountID: String
    ) async throws -> String {
        let result = try await callFunction(
            contractID: contractID,
            method: "ft_balance_of",
            arguments: ["account_id": accountID]
        )
        guard let value = try JSONSerialization.jsonObject(
                with: result,
                options: [.fragmentsAllowed]
              ) as? String,
              let canonical = ExactDecimalText.canonicalUnsignedInteger(value)
        else { throw NEARProviderError.invalidResponse("ft_balance") }
        return canonical
    }

    func storageMinimumBalance(contractID: String) async throws -> String {
        let result = try await callFunction(
            contractID: contractID,
            method: "storage_balance_bounds",
            arguments: [:]
        )
        guard let object = try JSONSerialization.jsonObject(with: result)
                as? [String: Any],
              let minimum = object["min"] as? String,
              let canonical = ExactDecimalText.canonicalUnsignedInteger(
                  minimum
              )
        else {
            throw NEARProviderError.invalidResponse("storage_bounds")
        }
        return canonical
    }

    func isStorageRegistered(
        contractID: String,
        accountID: String
    ) async throws -> Bool {
        let result = try await callFunction(
            contractID: contractID,
            method: "storage_balance_of",
            arguments: ["account_id": accountID]
        )
        return try JSONSerialization.jsonObject(with: result) is [String: Any]
    }

    func gasPrice() async throws -> String {
        guard let transport else { throw NEARProviderError.missingConfiguration }
        let result = try await transport.request(
            method: "gas_price",
            parameters: .array([.null])
        )
        guard let value = result.objectValue?["gas_price"]?.stringValue,
              let canonical = ExactDecimalText.canonicalUnsignedInteger(value)
        else { throw NEARProviderError.invalidResponse("gas_price") }
        return canonical
    }

    private func loadBalances(
        address: String,
        onNativeBalance: (@Sendable (String) async throws -> Void)? = nil
    ) async throws -> BalanceLoad {
        var rpc: NativeBalanceLoad?
        var index: FastAccountLoad?
        var didPublishNative = false
        try await withThrowingTaskGroup(
            of: InitialBalanceLoad.self
        ) { group in
            group.addTask { [self] in
                .rpc(try await loadRPCNativeBalance(address: address))
            }
            group.addTask { [self] in
                .index(try await loadFastAccount(address: address))
            }
            for try await load in group {
                switch load {
                case let .rpc(value): rpc = value
                case let .index(value): index = value
                }
                let nativeAtomic = rpc?.atomicAmount
                    ?? index?.nativeAtomicAmount
                if !didPublishNative, let nativeAtomic {
                    didPublishNative = true
                    try await onNativeBalance?(nativeAtomic)
                }
            }
        }

        let resolvedRPC = rpc ?? NativeBalanceLoad(
            atomicAmount: nil,
            failureCode: "near_native_balance_unavailable"
        )
        let resolvedIndex = index ?? FastAccountLoad(
            nativeAtomicAmount: nil,
            tokens: [],
            succeeded: false,
            failureCode: "near_fast_account_unavailable"
        )

        var failures = [
            resolvedRPC.failureCode,
            resolvedIndex.failureCode
        ].compactMap { $0 }
        guard let nativeAtomic = resolvedRPC.atomicAmount
                ?? resolvedIndex.nativeAtomicAmount
        else {
            throw NEARProviderError.providerRejected(
                failures.joined(separator: "_")
            )
        }
        var balances = [
            NEARAssetBalance(
                metadata: nil,
                amountText: try Self.userUnits(
                    atomic: nativeAtomic,
                    decimals: NEARConstants.decimals
                ),
                atomicAmount: nativeAtomic
            )
        ]
        var successfulAssetIDs = Set([
            NEARConstants.nativeAssetID
        ])

        var inventoryIsComplete = resolvedIndex.succeeded
        if resolvedIndex.tokens.count > 250 {
            inventoryIsComplete = false
            failures.append("near_token_inventory_truncated")
        }
        if resolvedIndex.succeeded {
            let tokenLoad = try await boundedTokenBalances(
                Array(resolvedIndex.tokens.prefix(250))
            )
            balances.append(contentsOf: tokenLoad.balances)
            successfulAssetIDs.formUnion(
                tokenLoad.successfulAssetIDs
            )
            failures.append(contentsOf: tokenLoad.failureCodes)
            inventoryIsComplete = inventoryIsComplete
                && tokenLoad.failureCodes.isEmpty
        } else {
            // Standard NEAR JSON-RPC cannot enumerate every fungible-token
            // contract owned by an account. It can still recover the bundled,
            // verified catalog independently when the account index is down.
            // Keep the snapshot non-authoritative so custom cached holdings are
            // never cleared merely because discovery was unavailable.
            let tokenLoad = try await catalogTokenBalances(address: address)
            balances.append(contentsOf: tokenLoad.balances)
            successfulAssetIDs.formUnion(
                tokenLoad.successfulAssetIDs
            )
            failures.append(contentsOf: tokenLoad.failureCodes)
        }

        return BalanceLoad(
            balances: balances,
            successfulAssetIDs: successfulAssetIDs,
            isAuthoritative: resolvedRPC.atomicAmount != nil
                && inventoryIsComplete,
            failureCodes: Array(Set(failures)).sorted()
        )
    }

    private func loadRPCNativeBalance(address: String) async throws
        -> NativeBalanceLoad {
        do {
            return NativeBalanceLoad(
                atomicAmount: try await nativeBalance(accountID: address),
                failureCode: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NEARProviderError {
            if case let .rpc(_, message) = error,
               message == "unknown_account" {
                return NativeBalanceLoad(
                    atomicAmount: "0",
                    failureCode: nil
                )
            }
            return NativeBalanceLoad(
                atomicAmount: nil,
                failureCode: error.diagnosticDescription
            )
        } catch {
            return NativeBalanceLoad(
                atomicAmount: nil,
                failureCode: "near_native_balance_unavailable"
            )
        }
    }

    private func loadFastAccount(address: String) async throws
        -> FastAccountLoad {
        let url = NEARConstants.fastNEARAPIBase
            .appending(path: "v1/account/\(address)/full")
        let response: NEARFastAPIResponse
        do {
            response = try await fastAPITransport.response(
                for: URLRequest(url: url),
                serviceID: "near_fast_account_read",
                acceptedStatusCodes: [404]
            )
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as NEARProviderError {
            return FastAccountLoad(
                nativeAtomicAmount: nil,
                tokens: [],
                succeeded: false,
                failureCode: error.diagnosticDescription
            )
        }
        catch {
            return FastAccountLoad(
                nativeAtomicAmount: nil,
                tokens: [],
                succeeded: false,
                failureCode: Self.failureCode(error)
            )
        }
        if response.statusCode == 404 {
            return FastAccountLoad(
                nativeAtomicAmount: "0",
                tokens: [],
                succeeded: true,
                failureCode: nil
            )
        }
        let account: FastAccount
        do {
            account = try JSONDecoder().decode(
                FastAccount.self,
                from: response.data
            )
        }
        catch {
            return FastAccountLoad(
                nativeAtomicAmount: nil,
                tokens: [],
                succeeded: false,
                failureCode: "near_invalid_response_fastnear_account"
            )
        }
        guard let nativeAtomic = ExactDecimalText.canonicalUnsignedInteger(
            account.state.balance
        ) else {
            return FastAccountLoad(
                nativeAtomicAmount: nil,
                tokens: [],
                succeeded: false,
                failureCode: "near_invalid_response_native_balance"
            )
        }
        let tokens = account.tokens.filter {
            ExactDecimalText.canonicalUnsignedInteger($0.balance)
                .map { $0 != "0" } ?? false
        }
        return FastAccountLoad(
            nativeAtomicAmount: nativeAtomic,
            tokens: tokens,
            succeeded: true,
            failureCode: nil
        )
    }

    private func boundedTokenBalances(
        _ tokens: [FastAccount.Token]
    ) async throws -> TokenBalanceLoad {
        var output: [NEARAssetBalance] = []
        var failures: [String] = []
        for start in stride(
            from: 0,
            to: tokens.count,
            by: NEARConstants.metadataConcurrencyLimit
        ) {
            try Task.checkCancellation()
            let end = min(
                start + NEARConstants.metadataConcurrencyLimit,
                tokens.count
            )
            let batch = Array(tokens[start..<end])
            let values = try await withThrowingTaskGroup(
                of: Result<NEARAssetBalance, NEARProviderError>.self,
                returning: [Result<NEARAssetBalance, NEARProviderError>].self
            ) { group in
                for token in batch {
                    group.addTask { [self] in
                        try Task.checkCancellation()
                        guard NEARAddress.isValid(token.contractID),
                              let atomic = ExactDecimalText
                                .canonicalUnsignedInteger(token.balance)
                        else {
                            return .failure(
                                .invalidResponse("token_inventory")
                            )
                        }
                        do {
                            let metadata = try await metadata(
                                contractID: token.contractID
                            )
                            let amount = try Self.userUnits(
                                atomic: atomic,
                                decimals: metadata.decimals
                            )
                            return .success(
                                NEARAssetBalance(
                                    metadata: metadata,
                                    amountText: amount,
                                    atomicAmount: atomic
                                )
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let error as NEARProviderError {
                            return .failure(error)
                        } catch {
                            return .failure(
                                .invalidResponse("token_metadata")
                            )
                        }
                    }
                }
                var values: [Result<NEARAssetBalance, NEARProviderError>] = []
                for try await value in group {
                    values.append(value)
                }
                return values
            }
            for value in values {
                switch value {
                case let .success(balance): output.append(balance)
                case let .failure(error):
                    failures.append(error.diagnosticDescription)
                }
            }
        }
        return TokenBalanceLoad(
            balances: output.sorted {
                ($0.metadata?.rank ?? Int.max)
                    < ($1.metadata?.rank ?? Int.max)
            },
            successfulAssetIDs: Set(output.map(\.assetID)),
            failureCodes: Array(Set(failures)).sorted()
        )
    }

    private func catalogTokenBalances(address: String) async throws
        -> TokenBalanceLoad {
        let values = try await withThrowingTaskGroup(
            of: Result<
                (String, NEARAssetBalance?),
                NEARProviderError
            >.self,
            returning: [Result<
                (String, NEARAssetBalance?),
                NEARProviderError
            >].self
        ) { group in
            for token in NEARTokenCatalog.all {
                group.addTask { [self] in
                    do {
                        let assetID = AssetIdentityKey.make(
                            networkID: NEARConstants.networkID,
                            contractAddress: token.contractID
                        )
                        let atomic = try await fungibleTokenBalance(
                            contractID: token.contractID,
                            accountID: address
                        )
                        guard atomic != "0" else {
                            return .success((assetID, nil))
                        }
                        let metadata = NEARTokenMetadata(
                            contractID: token.contractID,
                            name: token.name,
                            symbol: token.symbol,
                            decimals: token.decimals,
                            iconURL: nil,
                            isVerified: true,
                            rank: token.rank
                        )
                        return .success(
                            (
                                assetID,
                                NEARAssetBalance(
                                    metadata: metadata,
                                    amountText: try Self.userUnits(
                                        atomic: atomic,
                                        decimals: token.decimals
                                    ),
                                    atomicAmount: atomic
                                )
                            )
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as NEARProviderError {
                        return .failure(error)
                    } catch {
                        return .failure(
                            .invalidResponse("catalog_token_balance")
                        )
                    }
                }
            }
            var output: [Result<
                (String, NEARAssetBalance?),
                NEARProviderError
            >] = []
            for try await value in group { output.append(value) }
            return output
        }
        var balances: [NEARAssetBalance] = []
        var successfulAssetIDs = Set<String>()
        var failures: [String] = []
        for value in values {
            switch value {
            case let .success((assetID, balance)):
                successfulAssetIDs.insert(assetID)
                if let balance { balances.append(balance) }
            case let .failure(error):
                failures.append(error.diagnosticDescription)
            }
        }
        return TokenBalanceLoad(
            balances: balances.sorted {
                ($0.metadata?.rank ?? Int.max)
                    < ($1.metadata?.rank ?? Int.max)
            },
            successfulAssetIDs: successfulAssetIDs,
            failureCodes: Array(Set(failures)).sorted()
        )
    }

    private func metadata(contractID: String) async throws
        -> NEARTokenMetadata {
        if let cached = metadataCache[contractID] { return cached }
        guard let transport else { throw NEARProviderError.missingConfiguration }
        let result = try await transport.request(
            method: "query",
            parameters: .object([
                "request_type": .string("call_function"),
                "finality": .string("final"),
                "account_id": .string(contractID),
                "method_name": .string("ft_metadata"),
                "args_base64": .string("e30=")
            ])
        )
        guard let bytes = result.objectValue?["result"]?.arrayValue else {
            throw NEARProviderError.invalidResponse("ft_metadata_result")
        }
        let data = Data(try bytes.map {
            guard let value = $0.integerValue, (0...255).contains(value)
            else { throw NEARProviderError.invalidResponse("metadata_byte") }
            return UInt8(value)
        })
        struct Metadata: Decodable {
            let name: String
            let symbol: String
            let decimals: Int
            let icon: String?
        }
        let decoded = try JSONDecoder().decode(Metadata.self, from: data)
        guard !decoded.name.isEmpty, !decoded.symbol.isEmpty,
              (0...38).contains(decoded.decimals)
        else { throw NEARProviderError.invalidResponse("ft_metadata") }
        let catalog = NEARTokenCatalog.byContract[contractID]
        let metadata = NEARTokenMetadata(
            contractID: contractID,
            name: catalog?.name ?? decoded.name,
            symbol: catalog?.symbol ?? decoded.symbol,
            decimals: catalog?.decimals ?? decoded.decimals,
            iconURL: decoded.icon.flatMap(Self.safeIconURL),
            isVerified: catalog != nil,
            rank: catalog?.rank ?? 10_000
        )
        metadataCache[contractID] = metadata
        return metadata
    }

    private func callFunction(
        contractID: String,
        method: String,
        arguments: [String: String]
    ) async throws -> Data {
        guard NEARAddress.isValid(contractID), let transport else {
            throw NEARProviderError.invalidContract
        }
        let argumentsData = try JSONSerialization.data(
            withJSONObject: arguments,
            options: [.sortedKeys]
        )
        let result = try await transport.request(
            method: "query",
            parameters: .object([
                "request_type": .string("call_function"),
                "finality": .string("final"),
                "account_id": .string(contractID),
                "method_name": .string(method),
                "args_base64": .string(
                    argumentsData.base64EncodedString()
                )
            ])
        )
        guard let bytes = result.objectValue?["result"]?.arrayValue else {
            throw NEARProviderError.invalidResponse("function_result")
        }
        return Data(try bytes.map {
            guard let value = $0.integerValue, (0...255).contains(value)
            else {
                throw NEARProviderError.invalidResponse("function_byte")
            }
            return UInt8(value)
        })
    }

    private func history(address: String) async throws -> [NEARHistoryItem] {
        try await historyProviderRouter.history(
            fastNEAR: { [self] in
                try await fastNEARHistory(address: address)
            },
            nearBlocks: { [nearBlocksHistoryClient] in
                try await nearBlocksHistoryClient.history(address: address)
            }
        )
    }

    private func fastNEARHistory(address: String) async throws
        -> [NEARHistoryItem] {
        let pageItems = try await historyPageItems(address: address)
        guard !pageItems.isEmpty else { return [] }
        let byHash = Dictionary(
            pageItems.map { ($0.transactionHash, $0) },
            uniquingKeysWith: { lhs, _ in lhs }
        )
        let hashes = Array(byHash.keys)
        let transactionDetails = try await NEARHistoryDetailsBatchLoader.load(
            hashes: hashes,
            batchSize: NEARConstants.historyDetailsBatchSize,
            maximumConcurrency:
                NEARConstants.historyDetailsConcurrencyLimit
        ) { [self] batch in
            try await historyDetails(hashes: batch)
        }
        var items: [NEARHistoryItem] = []
        for detail in transactionDetails {
            let hash = detail.objectValue?["transaction"]?
                .objectValue?["hash"]?.stringValue
            items.append(
                contentsOf: try await historyItems(
                    detail: detail,
                    address: address,
                    pageItem: hash.flatMap { byHash[$0] }
                )
            )
        }
        return Dictionary(
            items.map { ($0.id, $0) },
            uniquingKeysWith: { lhs, _ in lhs }
        ).values.sorted {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp > $1.timestamp
            }
            return $0.id < $1.id
        }
    }

    private func historyPageItems(address: String) async throws
        -> [NEARFastAccountHistoryPage.Item] {
        var output: [NEARFastAccountHistoryPage.Item] = []
        var resumeToken: String?
        for _ in 0..<NEARConstants.maximumHistoryPages {
            try Task.checkCancellation()
            var body: [String: Any] = [
                "account_id": address,
                "desc": true,
                "limit": NEARConstants.historyPageSize
            ]
            if let resumeToken { body["resume_token"] = resumeToken }
            let page = try await historyPage(body: body)
            output.append(contentsOf: page.items)
            guard !page.items.isEmpty,
                  let next = page.resumeToken,
                  !next.isEmpty,
                  next != resumeToken
            else { break }
            resumeToken = next
        }
        return output
    }

    private func historyPage(body: [String: Any]) async throws
        -> NEARFastAccountHistoryPage {
        var request = URLRequest(
            url: NEARConstants.fastNEARTxBase.appending(path: "v0/account")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response = try await fastAPITransport.response(
            for: request,
            serviceID: "near_fast_history_page"
        )
        do {
            return try JSONDecoder().decode(
                NEARFastAccountHistoryPage.self,
                from: response.data
            )
        } catch {
            throw NEARProviderError.invalidResponse("history_page_decoding")
        }
    }

    private func historyDetails(hashes: [String]) async throws
        -> [NEARJSONValue] {
        guard !hashes.isEmpty,
              hashes.count <= NEARConstants.historyDetailsBatchSize
        else {
            throw NEARProviderError.invalidResponse("history_batch")
        }
        var detailsRequest = URLRequest(
            url: NEARConstants.fastNEARTxBase
                .appending(path: "v0/transactions")
        )
        detailsRequest.httpMethod = "POST"
        detailsRequest.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        detailsRequest.httpBody = try JSONSerialization.data(
            withJSONObject: ["tx_hashes": hashes]
        )
        let response = try await fastAPITransport.response(
            for: detailsRequest,
            serviceID: "near_fast_history_details"
        )
        let details: NEARFastTransactionDetails
        do {
            details = try JSONDecoder().decode(
                NEARFastTransactionDetails.self,
                from: response.data
            )
        } catch {
            throw NEARProviderError.invalidResponse(
                "history_details_decoding"
            )
        }
        return details.transactions
    }

    func historyItems(
        detail: NEARJSONValue,
        address: String,
        pageItem: NEARFastAccountHistoryPage.Item?
    ) async throws -> [NEARHistoryItem] {
        guard let pageItem,
              let object = detail.objectValue,
              let transaction = object["transaction"]?.objectValue,
              let hash = transaction["hash"]?.stringValue,
              let signer = transaction["signer_id"]?.stringValue,
              let receiver = transaction["receiver_id"]?.stringValue,
              let actions = transaction["actions"]?.arrayValue,
              let timestampNS = UInt64(pageItem.timestamp)
        else { return [] }
        let timestamp = Double(timestampNS / 1_000_000_000)
        let nonce = transaction["nonce"]?.integerValue
        let feeAtomic = object["execution_outcome"]?.objectValue?["outcome"]?
            .objectValue?["tokens_burnt"]?.stringValue
        var items: [NEARHistoryItem] = []
        var topLevelNativeSignatures = Set<String>()
        for (index, action) in actions.enumerated() {
            guard let actionObject = action.objectValue else { continue }
            if let transfer = actionObject["Transfer"]?.objectValue,
               let atomic = transfer["deposit"]?.stringValue,
               ExactDecimalText.canonicalUnsignedInteger(atomic) != nil {
                let outgoing = signer == address
                guard outgoing || receiver == address else { continue }
                let amount = try Self.userUnits(
                    atomic: atomic,
                    decimals: NEARConstants.decimals
                )
                topLevelNativeSignatures.insert(
                    Self.transferSignature(
                        sender: signer,
                        recipient: receiver,
                        atomic: atomic
                    )
                )
                items.append(
                    NEARHistoryItem(
                        id: "\(hash):native:\(index)",
                        transactionHash: hash,
                        timestamp: timestamp,
                        failed: !pageItem.succeeded,
                        sender: signer,
                        recipient: receiver,
                        metadata: nil,
                        signedAmountText: outgoing ? "-\(amount)" : amount,
                        networkFeeAtomic: feeAtomic,
                        blockHeight: pageItem.height,
                        nonce: nonce
                    )
                )
            } else if let function = actionObject["FunctionCall"]?.objectValue,
                      let item = try await fungibleTokenHistoryItem(
                        function: function,
                        tokenContract: receiver,
                        signer: signer,
                        transactionHash: hash,
                        actionIndex: index,
                        address: address,
                        timestamp: timestamp,
                        failed: !pageItem.succeeded,
                        feeAtomic: feeAtomic,
                        blockHeight: pageItem.height,
                        nonce: nonce
                      ) {
                items.append(item)
            }
        }
        let receipts = object["receipts"]?.arrayValue ?? []
        for (receiptIndex, receiptValue) in receipts.enumerated() {
            guard let receiptEnvelope = receiptValue.objectValue,
                  let receipt = receiptEnvelope["receipt"]?.objectValue,
                  let sender = receipt["predecessor_id"]?.stringValue,
                  // NEAR protocol refunds are not incoming wallet transfers.
                  sender != "system",
                  let recipient = receipt["receiver_id"]?.stringValue,
                  let receiptPayload = receipt["receipt"]?.objectValue,
                  let actionReceipt = receiptPayload["Action"]?.objectValue,
                  let receiptActions = actionReceipt["actions"]?.arrayValue
            else { continue }
            for (actionIndex, action) in receiptActions.enumerated() {
                guard let transfer = action.objectValue?["Transfer"]?
                        .objectValue,
                      let atomic = transfer["deposit"]?.stringValue,
                      ExactDecimalText.canonicalUnsignedInteger(atomic) != nil,
                      sender == address || recipient == address
                else { continue }
                let signature = Self.transferSignature(
                    sender: sender,
                    recipient: recipient,
                    atomic: atomic
                )
                if topLevelNativeSignatures.remove(signature) != nil {
                    continue
                }
                let amount = try Self.userUnits(
                    atomic: atomic,
                    decimals: NEARConstants.decimals
                )
                items.append(
                    NEARHistoryItem(
                        id: "\(hash):receipt:\(receiptIndex):\(actionIndex)",
                        transactionHash: hash,
                        timestamp: timestamp,
                        failed: !pageItem.succeeded,
                        sender: sender,
                        recipient: recipient,
                        metadata: nil,
                        signedAmountText: sender == address
                            ? "-\(amount)" : amount,
                        networkFeeAtomic: signer == address
                            ? feeAtomic : nil,
                        blockHeight: pageItem.height,
                        nonce: nonce
                    )
                )
            }
        }
        return items
    }

    private func fungibleTokenHistoryItem(
        function: [String: NEARJSONValue],
        tokenContract: String,
        signer: String,
        transactionHash: String,
        actionIndex: Int,
        address: String,
        timestamp: Double,
        failed: Bool,
        feeAtomic: String?,
        blockHeight: Int64,
        nonce: Int64?
    ) async throws -> NEARHistoryItem? {
        guard let method = function["method_name"]?.stringValue,
              method == "ft_transfer" || method == "ft_transfer_call",
              let encoded = function["args"]?.stringValue,
              let data = Data(base64Encoded: encoded),
              let arguments = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let recipient = arguments["receiver_id"] as? String,
              let atomic = arguments["amount"] as? String,
              ExactDecimalText.canonicalUnsignedInteger(atomic) != nil,
              signer == address || recipient == address
        else { return nil }
        let metadata = try await metadata(contractID: tokenContract)
        let amount = try Self.userUnits(
            atomic: atomic,
            decimals: metadata.decimals
        )
        return NEARHistoryItem(
            id: "\(transactionHash):ft:\(actionIndex)",
            transactionHash: transactionHash,
            timestamp: timestamp,
            failed: failed,
            sender: signer,
            recipient: recipient,
            metadata: metadata,
            signedAmountText: signer == address ? "-\(amount)" : amount,
            networkFeeAtomic: signer == address ? feeAtomic : nil,
            blockHeight: blockHeight,
            nonce: nonce
        )
    }

    private static func transferSignature(
        sender: String,
        recipient: String,
        atomic: String
    ) -> String {
        "\(sender)|\(recipient)|\(atomic)"
    }

}
