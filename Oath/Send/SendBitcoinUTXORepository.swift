import CryptoKit
import Foundation
import WalletCore

enum SendBitcoinUTXORepositoryError: Error, Hashable, Sendable {
    case selectedWalletUnavailable
    case accountUnavailable
    case invalidAccountAddress
    case provider(String)
    case invalidResponse(String)
    case tooManyOutputs

    var localizedMessage: String {
        switch self {
        case .selectedWalletUnavailable:
            WalletLocalization.string(
                "send.coin_control.error.selected_wallet"
            )
        case .accountUnavailable:
            WalletLocalization.string(
                "send.coin_control.error.account_unavailable"
            )
        case .invalidAccountAddress:
            WalletLocalization.string(
                "send.coin_control.error.invalid_account"
            )
        case let .provider(code):
            EnglishNumbers.localized(
                "send.coin_control.error.provider",
                code
            )
        case let .invalidResponse(code):
            EnglishNumbers.localized(
                "send.coin_control.error.invalid_response",
                code
            )
        case .tooManyOutputs:
            WalletLocalization.string(
                "send.coin_control.error.too_many_outputs"
            )
        }
    }
}

struct SendBitcoinUTXORepository: Sendable {
    static let shared = SendBitcoinUTXORepository(
        databaseProvider: WalletDatabaseRuntime.require
    )

    private static let maximumOutputCount = 25_000
    private static let maximumResponseBytes = 8_388_608
    private static let maximumRankedFallbackConcurrency = 8

    private let databaseProvider:
        @Sendable () throws -> WalletDatabase
    private let dataStore: WalletDataStore
    private let electrum: BitcoinFamilyElectrumClient

    private struct HDOutputResponse: Sendable {
        let state: BitcoinHDAddressState
        let value: JSONValue
    }

    init(
        database: WalletDatabase,
        dataStore: WalletDataStore = .shared,
        electrum: BitcoinFamilyElectrumClient = .shared
    ) {
        databaseProvider = { database }
        self.dataStore = dataStore
        self.electrum = electrum
    }

    private init(
        databaseProvider:
            @escaping @Sendable () throws -> WalletDatabase,
        dataStore: WalletDataStore = .shared,
        electrum: BitcoinFamilyElectrumClient = .shared
    ) {
        self.databaseProvider = databaseProvider
        self.dataStore = dataStore
        self.electrum = electrum
    }

    func outputs(for chain: BitcoinFamilyChain) async throws
        -> [SendBitcoinUTXO] {
        do {
            let database = try databaseProvider()
            guard let identity = try await database.selectedWalletIdentity()
            else {
                throw SendBitcoinUTXORepositoryError
                    .selectedWalletUnavailable
            }
            let accounts = try await dataStore.accounts(
                walletID: identity.walletID
            )
            guard
                let account = accounts.first(where: {
                    $0.networkID == chain.networkID && $0.isEnabled
                })
            else {
                throw SendBitcoinUTXORepositoryError.accountUnavailable
            }
            let outputs: [SendBitcoinUTXO]
            if chain.supportsFamilyHD,
               try await database.ensureBitcoinFamilyHDWallet(walletID: identity.walletID, chain: chain) {
                outputs = try await loadFamilyHDOutputs(database: database, walletID: identity.walletID, chain: chain)
            } else if chain == .bitcoin,
               try await database.muunRecoveryWallet(
                   walletID: identity.walletID
               ) != nil {
                outputs = try await loadMuunOutputs(
                    database: database,
                    walletID: identity.walletID
                )
            } else if chain == .bitcoin,
               try await database.ensureBitcoinHDWallet(
                   walletID: identity.walletID
               ) {
                outputs = try await loadHDOutputs(
                    database: database,
                    walletID: identity.walletID
                )
            } else if chain == .bitcoin,
                      try await database.bitcoinSingleKeyWallet(
                          walletID: identity.walletID
                      ) != nil {
                outputs = try await loadSingleKeyOutputs(
                    database: database,
                    walletID: identity.walletID
                )
            } else {
                outputs = try await loadOutputs(
                    chain: chain,
                    accountAddress: account.address
                )
            }
            let pending = try await databaseProvider().pendingBitcoinSpendResources(
                walletID: identity.walletID, networkID: chain.networkID, accountAddress: account.address
            )
            return SendSpendResource.availableBitcoinOutputs(outputs, excluding: pending)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SendBitcoinUTXORepositoryError {
            throw error
        } catch let error as BitcoinFamilyElectrumError {
            let repositoryError =
                SendBitcoinUTXORepositoryError.provider(
                    Self.electrumCode(error)
                )
            throw repositoryError
        } catch {
            let repositoryError =
                SendBitcoinUTXORepositoryError.provider(
                    Self.errorTypeCode(error)
                )
            throw repositoryError
        }
    }

    /// Loads UTXOs for the exact account bound to the reviewed Send. Review and
    /// Submission must never independently pick the first enabled account
    /// because a wallet can contain multiple accounts for the same
    /// Bitcoin-family network; Submission also verifies this address against
    /// the signing key before use.
    func outputs(
        for chain: BitcoinFamilyChain,
        accountAddress: String,
        walletID: String? = nil,
        minimumExpectedValueAtomic: String = "0",
        requiredOutpointIDs: Set<String> = []
    ) async throws -> [SendBitcoinUTXO] {
        do {
            let outputs: [SendBitcoinUTXO]
            if chain.supportsFamilyHD, let walletID,
               try await databaseProvider().ensureBitcoinFamilyHDWallet(walletID: walletID, chain: chain) {
                outputs = try await loadFamilyHDOutputs(database: databaseProvider(), walletID: walletID, chain: chain)
            } else if chain == .bitcoin,
               let walletID {
                let database = try databaseProvider()
                if try await database.muunRecoveryWallet(
                    walletID: walletID
                ) != nil {
                    outputs = try await loadMuunOutputs(
                        database: database,
                        walletID: walletID,
                        minimumExpectedValueAtomic:
                            minimumExpectedValueAtomic,
                        requiredOutpointIDs: requiredOutpointIDs
                    )
                } else if try await database.ensureBitcoinHDWallet(
                    walletID: walletID
                ) {
                    outputs = try await loadHDOutputs(
                        database: database,
                        walletID: walletID,
                        minimumExpectedValueAtomic:
                            minimumExpectedValueAtomic,
                        requiredOutpointIDs: requiredOutpointIDs
                    )
                } else if try await database.bitcoinSingleKeyWallet(
                    walletID: walletID
                ) != nil {
                    outputs = try await loadSingleKeyOutputs(
                        database: database,
                        walletID: walletID,
                        minimumExpectedValueAtomic:
                            minimumExpectedValueAtomic,
                        requiredOutpointIDs: requiredOutpointIDs
                    )
                } else {
                    outputs = try await loadOutputs(
                        chain: chain,
                        accountAddress: accountAddress,
                        minimumExpectedValueAtomic:
                            minimumExpectedValueAtomic,
                        requiredOutpointIDs: requiredOutpointIDs
                    )
                }
            } else {
                outputs = try await loadOutputs(
                    chain: chain,
                    accountAddress: accountAddress,
                    minimumExpectedValueAtomic:
                        minimumExpectedValueAtomic,
                    requiredOutpointIDs: requiredOutpointIDs
                )
            }
            let pending = try await databaseProvider().pendingBitcoinSpendResources(
                walletID: walletID, networkID: chain.networkID, accountAddress: accountAddress
            )
            return SendSpendResource.availableBitcoinOutputs(outputs, excluding: pending)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SendBitcoinUTXORepositoryError {
            throw error
        } catch let error as BitcoinFamilyElectrumError {
            let repositoryError = SendBitcoinUTXORepositoryError.provider(
                Self.electrumCode(error)
            )
            throw repositoryError
        } catch {
            let repositoryError = SendBitcoinUTXORepositoryError.provider(
                Self.errorTypeCode(error)
            )
            throw repositoryError
        }
    }

    private func loadHDOutputs(
        database: WalletDatabase,
        walletID: String,
        minimumExpectedValueAtomic: String = "0",
        requiredOutpointIDs: Set<String> = []
    ) async throws -> [SendBitcoinUTXO] {
        let expected: BitcoinFamilyAtomicInteger
        do {
            expected = try BitcoinFamilyAtomicInteger(
                validating: minimumExpectedValueAtomic
            )
        } catch {
            throw SendBitcoinUTXORepositoryError
                .invalidResponse("minimum_expected_value")
        }
        guard !expected.isNegative else {
            throw SendBitcoinUTXORepositoryError
                .invalidResponse("minimum_expected_value")
        }

        async let discoveryValue = BitcoinHDDiscoveryService(
            database: database
        ).discover(walletID: walletID)
        async let silentValue = BitcoinSilentPaymentSyncService(
            database: database
        ).refresh(walletID: walletID)
        async let tipValue = electrum.call(
            chain: .bitcoin,
            method: "blockchain.headers.subscribe"
        )
        let (discovery, silent, tip) = try await (
            discoveryValue,
            silentValue,
            tipValue
        )
        let fundedStates = discovery.states.filter {
            $0.balanceAtomic > .zero
        }

        let responses = try await loadHDOutputResponses(
            states: fundedStates
        )

        var identifiers = Set<String>()
        var outputs: [SendBitcoinUTXO] = []
        for response in responses {
            let parsed = try Self.parse(
                outputs: response.value,
                tip: tip,
                chain: .bitcoin,
                owner: response.state.derived
            )
            guard outputs.count + parsed.count <= Self.maximumOutputCount
            else {
                throw SendBitcoinUTXORepositoryError.tooManyOutputs
            }
            for output in parsed {
                guard identifiers.insert(output.id).inserted else {
                    throw SendBitcoinUTXORepositoryError
                        .invalidResponse("duplicate_outpoint")
                }
                outputs.append(output)
            }
        }
        guard let tipHeight = tip.object?["height"]?.exactInt64,
              tipHeight >= 0 else {
            throw SendBitcoinUTXORepositoryError
                .invalidResponse("tip_height")
        }
        for silentOutput in silent.outputs where !silentOutput.isSpent {
            let height = Int64(silentOutput.blockHeight ?? 0)
            let confirmations = height > 0 && tipHeight >= height
                ? tipHeight - height + 1
                : 0
            let output = SendBitcoinUTXO(
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                outpoint: SendBitcoinOutpoint(
                    transactionHash: silentOutput.transactionHash,
                    outputIndex: silentOutput.outputIndex
                ),
                valueAtomic: silentOutput.valueAtomic.decimalText,
                blockHeight: height,
                confirmations: confirmations,
                silentPaymentOwner: silentOutput
            )
            guard output.isValid,
                  identifiers.insert(output.id).inserted else {
                throw SendBitcoinUTXORepositoryError
                    .invalidResponse("silent_payment_outpoint")
            }
            outputs.append(output)
        }
        guard outputs.count <= Self.maximumOutputCount else {
            throw SendBitcoinUTXORepositoryError.tooManyOutputs
        }

        // Both values are consistency hints. A just-broadcast transaction can
        // legitimately make the live total lower than the persisted snapshot,
        // while manual selection is resolved against the authoritative live
        // outpoint set by the transaction service.
        _ = expected
        _ = requiredOutpointIDs
        return outputs.sorted(by: SendBitcoinUTXOSorting.precedes)
    }

    private func loadMuunOutputs(
        database: WalletDatabase,
        walletID: String,
        minimumExpectedValueAtomic: String = "0",
        requiredOutpointIDs: Set<String> = []
    ) async throws -> [SendBitcoinUTXO] {
        let expected: BitcoinFamilyAtomicInteger
        do {
            expected = try BitcoinFamilyAtomicInteger(
                validating: minimumExpectedValueAtomic
            )
        } catch {
            throw SendBitcoinUTXORepositoryError
                .invalidResponse("minimum_expected_value")
        }
        guard !expected.isNegative else {
            throw SendBitcoinUTXORepositoryError
                .invalidResponse("minimum_expected_value")
        }
        async let discoveryValue = MuunRecoveryDiscoveryService(
            database: database
        ).discover(walletID: walletID)
        async let tipValue = electrum.call(
            chain: .bitcoin,
            method: "blockchain.headers.subscribe"
        )
        let (discovery, tip) = try await (discoveryValue, tipValue)
        let funded = discovery.states.filter { $0.balanceAtomic > .zero }
        guard !funded.isEmpty else { return [] }
        let hashes = funded.map(\.derived.scriptHash)
        let values = try await electrum.callStringParameterBatch(
            chain: .bitcoin,
            method: "blockchain.scripthash.listunspent",
            parameters: hashes,
            maximumResponseBytes: Self.maximumResponseBytes
        )
        guard values.count == funded.count else {
            throw SendBitcoinUTXORepositoryError
                .invalidResponse("batch_output_count")
        }
        let valueByHash = Dictionary(
            uniqueKeysWithValues: values.map {
                ($0.parameter, $0.value)
            }
        )
        var identifiers = Set<String>()
        var outputs: [SendBitcoinUTXO] = []
        for state in funded {
            guard let value = valueByHash[state.derived.scriptHash] else {
                throw SendBitcoinUTXORepositoryError
                    .invalidResponse("batch_output_missing")
            }
            let parsed = try Self.parse(
                outputs: value,
                tip: tip,
                chain: .bitcoin,
                muunOwner: state.derived
            )
            guard outputs.count + parsed.count <= Self.maximumOutputCount
            else {
                throw SendBitcoinUTXORepositoryError.tooManyOutputs
            }
            for output in parsed {
                guard identifiers.insert(output.id).inserted else {
                    throw SendBitcoinUTXORepositoryError
                        .invalidResponse("duplicate_outpoint")
                }
                outputs.append(output)
            }
        }
        _ = expected
        _ = requiredOutpointIDs
        return outputs.sorted(by: SendBitcoinUTXOSorting.precedes)
    }

    private func loadSingleKeyOutputs(
        database: WalletDatabase,
        walletID: String,
        minimumExpectedValueAtomic: String = "0",
        requiredOutpointIDs: Set<String> = []
    ) async throws -> [SendBitcoinUTXO] {
        let expected: BitcoinFamilyAtomicInteger
        do {
            expected = try BitcoinFamilyAtomicInteger(
                validating: minimumExpectedValueAtomic
            )
        } catch {
            throw SendBitcoinUTXORepositoryError
                .invalidResponse("minimum_expected_value")
        }
        guard !expected.isNegative else {
            throw SendBitcoinUTXORepositoryError
                .invalidResponse("minimum_expected_value")
        }

        async let discoveryValue = BitcoinSingleKeyDiscoveryService(
            database: database
        ).discover(walletID: walletID)
        async let tipValue = electrum.call(
            chain: .bitcoin,
            method: "blockchain.headers.subscribe"
        )
        let (discovery, tip) = try await (discoveryValue, tipValue)
        let fundedStates = discovery.states.filter {
            $0.balanceAtomic > .zero
        }
        let responses = try await loadHDOutputResponses(
            states: fundedStates
        )

        var identifiers = Set<String>()
        var outputs: [SendBitcoinUTXO] = []
        for response in responses {
            let parsed = try Self.parse(
                outputs: response.value,
                tip: tip,
                chain: .bitcoin,
                owner: response.state.derived
            )
            guard outputs.count + parsed.count <= Self.maximumOutputCount
            else {
                throw SendBitcoinUTXORepositoryError.tooManyOutputs
            }
            for output in parsed {
                guard identifiers.insert(output.id).inserted else {
                    throw SendBitcoinUTXORepositoryError
                        .invalidResponse("duplicate_outpoint")
                }
                outputs.append(output)
            }
        }

        // These persisted values are ranking and continuity hints only. The
        // live Electrum outpoint set remains authoritative after a broadcast.
        _ = expected
        _ = requiredOutpointIDs
        return outputs.sorted(by: SendBitcoinUTXOSorting.precedes)
    }

    /// Loads every funded owner script through the production batch transport.
    /// A response that is behind the balance discovery result is retried through
    /// the ranked multi-provider path, with bounded concurrency independent of
    /// the number of generated Bitcoin addresses.
    private func loadHDOutputResponses(
        states: [BitcoinHDAddressState],
        chain: BitcoinFamilyChain = .bitcoin
    ) async throws -> [HDOutputResponse] {
        guard !states.isEmpty else { return [] }
        let scriptHashes = states.map(\.derived.scriptHash)
        guard Set(scriptHashes).count == scriptHashes.count else {
            throw SendBitcoinUTXORepositoryError
                .invalidResponse("duplicate_script_hash")
        }
        let batchValues = try await electrum.callStringParameterBatch(
            chain: chain,
            method: "blockchain.scripthash.listunspent",
            parameters: scriptHashes,
            maximumResponseBytes: Self.maximumResponseBytes
        )
        guard batchValues.count == states.count else {
            throw SendBitcoinUTXORepositoryError
                .invalidResponse("batch_output_count")
        }
        let expectedScriptHashes = Set(scriptHashes)
        var batchByScriptHash: [String: JSONValue] = [:]
        batchByScriptHash.reserveCapacity(batchValues.count)
        for batchValue in batchValues {
            guard expectedScriptHashes.contains(batchValue.parameter),
                  batchByScriptHash.updateValue(
                      batchValue.value,
                      forKey: batchValue.parameter
                  ) == nil else {
                throw SendBitcoinUTXORepositoryError
                    .invalidResponse("batch_output_identity")
            }
        }
        guard batchByScriptHash.count == states.count else {
            throw SendBitcoinUTXORepositoryError
                .invalidResponse("batch_output_identity")
        }

        var accepted: [HDOutputResponse] = []
        var fallbackStates: [BitcoinHDAddressState] = []
        accepted.reserveCapacity(states.count)
        fallbackStates.reserveCapacity(states.count)
        for state in states {
            guard let value = batchByScriptHash[
                state.derived.scriptHash
            ] else {
                throw SendBitcoinUTXORepositoryError
                    .invalidResponse("batch_output_missing")
            }
            let rating = try Self.readRating(
                outputs: value,
                chain: chain,
                minimumExpectedValue: state.balanceAtomic,
                requiredOutpointIDs: []
            )
            if rating.satisfiesRequirement {
                accepted.append(
                    HDOutputResponse(state: state, value: value)
                )
            } else {
                fallbackStates.append(state)
            }
        }
        accepted.append(
            contentsOf: try await loadRankedHDOutputResponses(
                states: fallbackStates, chain: chain
            )
        )
        return accepted
    }

    private func loadRankedHDOutputResponses(
        states: [BitcoinHDAddressState],
        chain: BitcoinFamilyChain = .bitcoin
    ) async throws -> [HDOutputResponse] {
        guard !states.isEmpty else { return [] }
        return try await withThrowingTaskGroup(
            of: HDOutputResponse.self
        ) { group in
            var nextIndex = 0
            func enqueueNext() {
                guard nextIndex < states.count else { return }
                let state = states[nextIndex]
                nextIndex += 1
                group.addTask {
                    let value = try await electrum.callRankedRead(
                        chain: chain,
                        method: "blockchain.scripthash.listunspent",
                        params: Self.listUnspentParameters(
                            chain: chain,
                            scriptHash: state.derived.scriptHash
                        ),
                        maximumResponseBytes: Self.maximumResponseBytes,
                        rating: { value in
                            try Self.readRating(
                                outputs: value,
                                chain: chain,
                                minimumExpectedValue: state.balanceAtomic,
                                requiredOutpointIDs: []
                            )
                        }
                    )
                    return HDOutputResponse(state: state, value: value)
                }
            }
            for _ in 0..<min(
                Self.maximumRankedFallbackConcurrency,
                states.count
            ) {
                enqueueNext()
            }
            var responses: [HDOutputResponse] = []
            responses.reserveCapacity(states.count)
            while let response = try await group.next() {
                responses.append(response)
                enqueueNext()
            }
            return responses
        }
    }

    private func loadFamilyHDOutputs(database: WalletDatabase, walletID: String,
                                     chain: BitcoinFamilyChain) async throws -> [SendBitcoinUTXO] {
        async let scan = BitcoinFamilyHDDiscoveryService(database: database, electrum: electrum)
            .discover(walletID: walletID, chain: chain)
        async let tipValue = electrum.call(chain: chain, method: "blockchain.headers.subscribe")
        let (discovery, tip) = try await (scan, tipValue)
        let states = discovery.states.filter { $0.balanceAtomic.isPositive }
        let responses = try await loadHDOutputResponses(states: states, chain: chain)
        var outputs: [SendBitcoinUTXO] = []
        for response in responses {
            outputs += try Self.parse(outputs: response.value, tip: tip, chain: chain, owner: response.state.derived)
        }
        guard outputs.count <= Self.maximumOutputCount, Set(outputs.map(\.id)).count == outputs.count else {
            throw SendBitcoinUTXORepositoryError.invalidResponse("family_hd_duplicate_utxos")
        }
        // Verify each reported coin against its actual transaction output before signing.
        let hashes = Array(Set(outputs.map(\.outpoint.transactionHash)))
        let raw = try await electrum.callStringParameterBatch(chain: chain, method: "blockchain.transaction.get",
            parameters: hashes, maximumResponseBytes: Self.maximumResponseBytes)
        var transactions: [String: BitcoinRawTransaction] = [:]
        for value in raw {
            guard let hex = value.value.string, let tx = BitcoinRawTransaction(hex: hex),
                  tx.transactionID == value.parameter else {
                throw SendBitcoinUTXORepositoryError.invalidResponse("family_hd_previous_transaction")
            }
            transactions[value.parameter] = tx
        }
        for output in outputs {
            guard let tx = transactions[output.outpoint.transactionHash],
                  tx.outputs.indices.contains(output.outpoint.outputIndex), let owner = output.owner,
                  tx.outputs[output.outpoint.outputIndex].script == owner.scriptPubKey,
                  tx.outputs[output.outpoint.outputIndex].value.decimalText == output.valueAtomic else {
                throw SendBitcoinUTXORepositoryError.invalidResponse("family_hd_previous_output")
            }
        }
        return outputs.sorted(by: SendBitcoinUTXOSorting.precedes)
    }

    private func loadOutputs(
        chain: BitcoinFamilyChain,
        accountAddress: String,
        minimumExpectedValueAtomic: String = "0",
        requiredOutpointIDs: Set<String> = []
    ) async throws -> [SendBitcoinUTXO] {
        guard chain.coin.validate(address: accountAddress),
              !accountAddress.isEmpty
        else {
            throw SendBitcoinUTXORepositoryError.invalidAccountAddress
        }
        let script = BitcoinScript.lockScriptForAddress(
            address: accountAddress,
            coin: chain.coin
        ).data
        guard !script.isEmpty else {
            throw SendBitcoinUTXORepositoryError.invalidAccountAddress
        }
        let scriptHash = Data(SHA256.hash(data: script))
            .reversed()
            .map { String(format: "%02x", $0) }
            .joined()
        let minimumExpectedValue: BitcoinFamilyAtomicInteger
        do {
            minimumExpectedValue = try BitcoinFamilyAtomicInteger(
                validating: minimumExpectedValueAtomic
            )
        } catch {
            throw SendBitcoinUTXORepositoryError
                .invalidResponse("minimum_expected_value")
        }
        guard !minimumExpectedValue.isNegative else {
            throw SendBitcoinUTXORepositoryError
                .invalidResponse("minimum_expected_value")
        }
        async let outputValue = electrum.callRankedRead(
            chain: chain,
            method: "blockchain.scripthash.listunspent",
            params: Self.listUnspentParameters(
                chain: chain,
                scriptHash: scriptHash
            ),
            maximumResponseBytes: Self.maximumResponseBytes,
            rating: { value in
                try Self.readRating(
                    outputs: value,
                    chain: chain,
                    minimumExpectedValue: minimumExpectedValue,
                    requiredOutpointIDs: requiredOutpointIDs
                )
            }
        )
        async let tipValue = electrum.call(
            chain: chain,
            method: "blockchain.headers.subscribe"
        )
        let (rawOutputs, rawTip) = try await (
            outputValue,
            tipValue
        )
        let parsedOutputs = try Self.parse(
            outputs: rawOutputs,
            tip: rawTip,
            chain: chain
        )
        // `minimumExpectedValue` comes from the last persisted wallet
        // snapshot. It is intentionally only a ranking hint so Electrum can
        // prefer a complete response when one endpoint is lagging. A recent
        // broadcast can legitimately make every live UTXO response lower than
        // that cached value. In that case the best ranked live listunspent
        // response is authoritative and the transaction planner decides
        // whether the newly requested amount remains spendable.
        return parsedOutputs
    }

    static func readRating(
        outputs: JSONValue,
        chain: BitcoinFamilyChain,
        minimumExpectedValue: BitcoinFamilyAtomicInteger,
        requiredOutpointIDs: Set<String>
    ) throws -> BitcoinFamilyElectrumReadRating {
        let parsed = try parse(
            outputs: outputs,
            tip: .object(["height": .number(Decimal(0))]),
            chain: chain
        )
        var availableValue = BitcoinFamilyAtomicInteger.zero
        var returnedOutpointIDs = Set<String>()
        returnedOutpointIDs.reserveCapacity(parsed.count)
        for output in parsed {
            availableValue = availableValue.adding(
                try BitcoinFamilyAtomicInteger(
                    validating: output.valueAtomic
                )
            )
            returnedOutpointIDs.insert(output.id)
        }
        let requiredMatchCount = requiredOutpointIDs.reduce(into: 0) {
            count, outpointID in
            if returnedOutpointIDs.contains(outpointID) {
                count += 1
            }
        }
        return BitcoinFamilyElectrumReadRating(
            satisfiesRequirement:
                availableValue >= minimumExpectedValue
                    && requiredMatchCount == requiredOutpointIDs.count,
            requiredMatchCount: requiredMatchCount,
            availableValue: availableValue
        )
    }

    static func listUnspentParameters(
        chain: BitcoinFamilyChain,
        scriptHash: String
    ) -> [AnyEncodable] {
        if chain == .bitcoinCash {
            return [
                AnyEncodable(scriptHash),
                AnyEncodable("exclude_tokens")
            ]
        }
        return [AnyEncodable(scriptHash)]
    }

    static func parse(
        outputs: JSONValue,
        tip: JSONValue,
        chain: BitcoinFamilyChain,
        owner: BitcoinHDDerivedAddress? = nil,
        muunOwner: MuunRecoveryDerivedAddress? = nil
    ) throws -> [SendBitcoinUTXO] {
        guard
            let items = outputs.array,
            let tipHeight = tip.object?["height"]?.exactInt64,
            tipHeight >= 0
        else {
            throw SendBitcoinUTXORepositoryError
                .invalidResponse("container")
        }
        guard items.count <= maximumOutputCount else {
            throw SendBitcoinUTXORepositoryError.tooManyOutputs
        }
        var identifiers = Set<String>()
        var parsed: [SendBitcoinUTXO] = []
        parsed.reserveCapacity(items.count)
        for itemValue in items {
            guard
                let item = itemValue.object,
                let transactionHash = item["tx_hash"]?.string,
                let value = item["value"]?.exactInt64,
                value > 0,
                let heightValue = item["height"]?.exactInt64
            else {
                throw SendBitcoinUTXORepositoryError
                    .invalidResponse("output_fields")
            }
            guard let outputIndexValue = item["tx_pos"]?.exactInt64
            else {
                throw SendBitcoinUTXORepositoryError
                    .invalidResponse("output_index_type")
            }
            guard
                outputIndexValue >= 0,
                outputIndexValue <= Int64(UInt32.max),
                let outputIndex = Int(exactly: outputIndexValue)
            else {
                throw SendBitcoinUTXORepositoryError
                    .invalidResponse("output_index_range")
            }
            let outpoint = SendBitcoinOutpoint(
                transactionHash: transactionHash,
                outputIndex: outputIndex
            )
            guard outpoint.isValid else {
                throw SendBitcoinUTXORepositoryError
                    .invalidResponse("outpoint")
            }
            guard identifiers.insert(outpoint.id).inserted else {
                throw SendBitcoinUTXORepositoryError
                    .invalidResponse("duplicate_outpoint")
            }
            let height = max(0, heightValue)
            let confirmations: Int64
            if height > 0, tipHeight >= height {
                confirmations = tipHeight - height + 1
            } else {
                confirmations = 0
            }
            let output = SendBitcoinUTXO(
                networkID: chain.networkID,
                outpoint: outpoint,
                valueAtomic: String(value),
                blockHeight: height,
                confirmations: confirmations,
                owner: owner,
                muunOwner: muunOwner
            )
            guard output.isValid else {
                throw SendBitcoinUTXORepositoryError
                    .invalidResponse("output_validation")
            }
            parsed.append(output)
        }
        return parsed.sorted(by: SendBitcoinUTXOSorting.precedes)
    }

    private static func electrumCode(
        _ error: BitcoinFamilyElectrumError
    ) -> String {
        switch error {
        case .unavailable:
            "unavailable"
        case .invalidResponse:
            "invalid_response"
        case .responseTooLarge:
            "response_too_large"
        case let .rpc(code, _):
            "rpc_\(code)"
        case let .submissionNotAttempted(code):
            "submission_not_attempted_\(code)"
        }
    }

    static func errorTypeCode(_ error: Error) -> String {
        let characters = String(reflecting: type(of: error))
            .lowercased()
            .map {
                $0.isLetter || $0.isNumber ? $0 : "_"
            }
        return String(characters.prefix(80))
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(
            duration.components.seconds * 1_000
                + duration.components.attoseconds
                    / 1_000_000_000_000_000
        )
    }
}

private extension SendBitcoinUTXORepositoryError {
    var diagnosticCode: String {
        switch self {
        case .selectedWalletUnavailable:
            "selected_wallet_unavailable"
        case .accountUnavailable:
            "account_unavailable"
        case .invalidAccountAddress:
            "invalid_account_address"
        case let .provider(code):
            "provider_\(code)"
        case let .invalidResponse(code):
            "invalid_response_\(code)"
        case .tooManyOutputs:
            "too_many_outputs"
        }
    }
}
