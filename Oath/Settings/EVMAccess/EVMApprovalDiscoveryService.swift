import Foundation

enum EVMApprovalDiscoveryError: Error, Hashable, Sendable {
    case incompleteHistory(networkID: String)
    case invalidEvent(networkID: String)
}

struct EVMApprovalScanResult: Sendable {
    let accountID: String
    let networkID: String
    let active: [EVMOnChainApproval]
    let inactiveIDs: Set<String>
    let unresolvedCount: Int
}

private struct EVMApprovalCandidate: Hashable, Sendable {
    let id: String
    let accountID: String
    let networkID: String
    let ownerAddress: String
    let contractAddress: String
    let spenderAddress: String
    let kind: EVMApprovalKind
    let tokenID: String?
    let eventAmount: String?
    let eventEnabled: Bool
    let transactionHash: String?
    let blockNumber: String?
}

private struct EVMContractMetadata: Sendable {
    let name: String?
    let symbol: String?
    let decimals: Int?
}

private enum EVMApprovalValidation: Sendable {
    case active(EVMOnChainApproval)
    case inactive(String)
    case unresolved
}

struct EVMApprovalDiscoveryService: Sendable {
    typealias RPCFactory = @Sendable (String) throws
        -> SendEVMRPCClient

    private static let maximumPages = 250
    private static let validationBatchSize = 20
    private let logProvider: any EVMApprovalLogProviding
    private let rpcFactory: RPCFactory

    init(
        logProvider: any EVMApprovalLogProviding,
        rpcFactory: @escaping RPCFactory = {
            try SendEVMRPCClient(networkID: $0)
        }
    ) {
        self.logProvider = logProvider
        self.rpcFactory = rpcFactory
    }

    static func configured() throws -> EVMApprovalDiscoveryService {
        EVMApprovalDiscoveryService(
            logProvider: try EVMApprovalLogProvider.configured()
        )
    }

    func scan(
        account: DBWalletAccountRecord
    ) async throws -> EVMApprovalScanResult {
        guard account.isEnabled,
              !account.isWatchOnly,
              ReceiveNetworkCatalog.network(
                  for: account.networkID
              )?.blockchain.isEVM == true,
              SendAddressValidator.isValidEVMAddress(account.address)
        else {
            throw EVMApprovalDiscoveryError.invalidEvent(
                networkID: account.networkID
            )
        }
        let candidates = try await candidates(account: account)
        let rpc = try rpcFactory(account.networkID)
        let validation = await validate(
            candidates: candidates,
            rpc: rpc
        )
        var active: [EVMOnChainApproval] = []
        var inactiveIDs = Set<String>()
        var unresolvedCount = 0
        for item in validation {
            switch item {
            case let .active(approval):
                active.append(approval)
            case let .inactive(id):
                inactiveIDs.insert(id)
            case .unresolved:
                unresolvedCount += 1
            }
        }

        let metadata = await metadata(
            contracts: Set(active.map(\.contractAddress)),
            rpc: rpc
        )
        active = active.map { approval in
            let contractMetadata = metadata[
                approval.contractAddress.lowercased()
            ]
            return EVMOnChainApproval(
                id: approval.id,
                accountID: approval.accountID,
                networkID: approval.networkID,
                ownerAddress: approval.ownerAddress,
                contractAddress: approval.contractAddress,
                spenderAddress: approval.spenderAddress,
                kind: approval.kind,
                tokenID: approval.tokenID,
                amountAtomic: approval.amountAtomic,
                tokenName: contractMetadata?.name,
                tokenSymbol: contractMetadata?.symbol,
                decimals: approval.kind == .tokenAllowance
                    ? contractMetadata?.decimals
                    : nil,
                transactionHash: approval.transactionHash,
                blockNumber: approval.blockNumber,
                discoveredAt: approval.discoveredAt,
                lastValidatedAt: approval.lastValidatedAt,
                pendingRevocationTransactionHash: nil,
                pendingRevocationSubmittedAt: nil
            )
        }
        return EVMApprovalScanResult(
            accountID: account.id,
            networkID: account.networkID,
            active: active,
            inactiveIDs: inactiveIDs,
            unresolvedCount: unresolvedCount
        )
    }

    private func candidates(
        account: DBWalletAccountRecord
    ) async throws -> [EVMApprovalCandidate] {
        var nextPageToken: String?
        var visitedTokens = Set<String>()
        var latestByID: [String: EVMApprovalCandidate] = [:]
        for pageIndex in 0..<Self.maximumPages {
            let page = try await logProvider.page(
                networkID: account.networkID,
                ownerAddress: account.address,
                pageToken: nextPageToken
            )
            for log in page.logs {
                let candidate = try Self.candidate(
                    log: log,
                    account: account
                )
                if latestByID[candidate.id] == nil {
                    latestByID[candidate.id] = candidate
                }
            }
            guard let token = page.nextPageToken else {
                return Array(latestByID.values)
            }
            guard pageIndex + 1 < Self.maximumPages,
                  visitedTokens.insert(token).inserted else {
                throw EVMApprovalDiscoveryError.incompleteHistory(
                    networkID: account.networkID
                )
            }
            nextPageToken = token
        }
        throw EVMApprovalDiscoveryError.incompleteHistory(
            networkID: account.networkID
        )
    }

    private func validate(
        candidates: [EVMApprovalCandidate],
        rpc: SendEVMRPCClient
    ) async -> [EVMApprovalValidation] {
        var output: [EVMApprovalValidation] = []
        for start in stride(
            from: 0,
            to: candidates.count,
            by: Self.validationBatchSize
        ) {
            let end = min(
                start + Self.validationBatchSize,
                candidates.count
            )
            let batch = candidates[start..<end]
            let values = await withTaskGroup(
                of: EVMApprovalValidation.self,
                returning: [EVMApprovalValidation].self
            ) { group in
                for candidate in batch {
                    group.addTask {
                        await Self.validate(
                            candidate: candidate,
                            rpc: rpc
                        )
                    }
                }
                var values: [EVMApprovalValidation] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }
            output.append(contentsOf: values)
        }
        return output
    }

    private func metadata(
        contracts: Set<String>,
        rpc: SendEVMRPCClient
    ) async -> [String: EVMContractMetadata] {
        await withTaskGroup(
            of: (String, EVMContractMetadata).self,
            returning: [String: EVMContractMetadata].self
        ) { group in
            for contract in contracts {
                group.addTask {
                    let metadata = await Self.metadata(
                        contract: contract,
                        rpc: rpc
                    )
                    return (contract.lowercased(), metadata)
                }
            }
            var values: [String: EVMContractMetadata] = [:]
            for await (contract, metadata) in group {
                values[contract] = metadata
            }
            return values
        }
    }

    private static func candidate(
        log: EVMApprovalEventLog,
        account: DBWalletAccountRecord
    ) throws -> EVMApprovalCandidate {
        guard let eventTopic = log.topics.first else {
            throw EVMApprovalDiscoveryError.invalidEvent(
                networkID: account.networkID
            )
        }
        let owner = account.address.lowercased()
        let kind: EVMApprovalKind
        let spender: String
        let tokenID: String?
        let eventAmount: String?
        let enabled: Bool
        if eventTopic == EVMApprovalLogProvider.approvalTopic,
           log.topics.count == 3,
           let decodedSpender = EVMApprovalABI.topicAddress(log.topics[2]) {
            kind = .tokenAllowance
            spender = decodedSpender
            tokenID = nil
            eventAmount = try EVMApprovalABI.unsignedInteger(log.data)
            enabled = eventAmount != "0"
        } else if eventTopic == EVMApprovalLogProvider.approvalTopic,
                  log.topics.count == 4,
                  let decodedSpender = EVMApprovalABI.topicAddress(
                      log.topics[2]
                  ) {
            kind = .nftToken
            spender = decodedSpender
            tokenID = try EVMApprovalABI.topicUnsignedInteger(
                log.topics[3]
            )
            eventAmount = nil
            enabled = !EVMApprovalABI.isZeroAddress(decodedSpender)
        } else if eventTopic
                    == EVMApprovalLogProvider.approvalForAllTopic,
                  log.topics.count == 3,
                  let decodedOperator = EVMApprovalABI.topicAddress(
                      log.topics[2]
                  ) {
            kind = .operatorAccess
            spender = decodedOperator
            tokenID = nil
            eventAmount = nil
            enabled = try EVMApprovalABI.boolean(log.data)
        } else {
            throw EVMApprovalDiscoveryError.invalidEvent(
                networkID: account.networkID
            )
        }
        let id = EVMOnChainApproval.stableID(
            accountID: account.id,
            networkID: account.networkID,
            contractAddress: log.contractAddress,
            spenderAddress: spender,
            kind: kind,
            tokenID: tokenID
        )
        return EVMApprovalCandidate(
            id: id,
            accountID: account.id,
            networkID: account.networkID,
            ownerAddress: owner,
            contractAddress: log.contractAddress,
            spenderAddress: spender,
            kind: kind,
            tokenID: tokenID,
            eventAmount: eventAmount,
            eventEnabled: enabled,
            transactionHash: log.transactionHash,
            blockNumber: log.blockNumber
        )
    }

    private static func validate(
        candidate: EVMApprovalCandidate,
        rpc: SendEVMRPCClient
    ) async -> EVMApprovalValidation {
        guard candidate.eventEnabled else {
            return .inactive(candidate.id)
        }
        do {
            let currentSpender: String
            let amount: String?
            switch candidate.kind {
            case .tokenAllowance:
                let output = try await rpc.callContract(
                    contractAddress: candidate.contractAddress,
                    data: try EVMApprovalABI.allowanceCall(
                        ownerAddress: candidate.ownerAddress,
                        spenderAddress: candidate.spenderAddress
                    )
                )
                let allowance = try EVMApprovalABI
                    .unsignedInteger(output)
                guard allowance != "0" else {
                    return .inactive(candidate.id)
                }
                currentSpender = candidate.spenderAddress
                amount = allowance
            case .nftToken:
                let output = try await rpc.callContract(
                    contractAddress: candidate.contractAddress,
                    data: try EVMApprovalABI.getApprovedCall(
                        tokenID: candidate.tokenID ?? ""
                    )
                )
                guard let approved = EVMApprovalABI.address(output),
                      !EVMApprovalABI.isZeroAddress(approved) else {
                    return .inactive(candidate.id)
                }
                currentSpender = approved
                amount = nil
            case .operatorAccess:
                let output = try await rpc.callContract(
                    contractAddress: candidate.contractAddress,
                    data: try EVMApprovalABI.isApprovedForAllCall(
                        ownerAddress: candidate.ownerAddress,
                        operatorAddress: candidate.spenderAddress
                    )
                )
                guard try EVMApprovalABI.boolean(output) else {
                    return .inactive(candidate.id)
                }
                currentSpender = candidate.spenderAddress
                amount = nil
            }
            let now = Date()
            return .active(
                EVMOnChainApproval(
                    id: candidate.id,
                    accountID: candidate.accountID,
                    networkID: candidate.networkID,
                    ownerAddress: candidate.ownerAddress,
                    contractAddress: candidate.contractAddress,
                    spenderAddress: currentSpender,
                    kind: candidate.kind,
                    tokenID: candidate.tokenID,
                    amountAtomic: amount,
                    tokenName: nil,
                    tokenSymbol: nil,
                    decimals: nil,
                    transactionHash: candidate.transactionHash,
                    blockNumber: candidate.blockNumber,
                    discoveredAt: now,
                    lastValidatedAt: now,
                    pendingRevocationTransactionHash: nil,
                    pendingRevocationSubmittedAt: nil
                )
            )
        } catch {
            return .unresolved
        }
    }

    private static func metadata(
        contract: String,
        rpc: SendEVMRPCClient
    ) async -> EVMContractMetadata {
        async let nameOutput = try? await rpc.callContract(
            contractAddress: contract,
            data: "0x06fdde03"
        )
        async let symbolOutput = try? await rpc.callContract(
            contractAddress: contract,
            data: "0x95d89b41"
        )
        async let decimalsOutput = try? await rpc.callContract(
            contractAddress: contract,
            data: "0x313ce567"
        )
        let (nameValue, symbolValue, decimalsValue) = await (
            nameOutput,
            symbolOutput,
            decimalsOutput
        )
        let decimals: Int?
        if let decimalsValue,
           let decimalText = try? EVMApprovalABI
            .unsignedInteger(decimalsValue),
           let value = Int(decimalText),
           (0...255).contains(value) {
            decimals = value
        } else {
            decimals = nil
        }
        return EVMContractMetadata(
            name: nameValue.flatMap(EVMApprovalABI.metadataString),
            symbol: symbolValue.flatMap(EVMApprovalABI.metadataString),
            decimals: decimals
        )
    }
}
