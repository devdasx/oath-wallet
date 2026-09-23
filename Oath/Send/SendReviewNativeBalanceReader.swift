import Foundation
import WalletCore

struct SendReviewNativeBalance: Sendable {
    let balance: String
    var reserve = "0"
    var additionalCost = "0"
    var solanaRentMinimum: UInt64?
}

/// Uses existing chain clients and lossless atomic amounts. No cached portfolio
/// balance can authorize a transfer. Protocol reserves mirror submission rules.
struct SendReviewNativeBalanceReader: Sendable {
    let database: WalletDatabase

    func read(draft: SendDraft, fee: SendResolvedNetworkFee,
              account: DBWalletAccountRecord) async throws -> SendReviewNativeBalance {
        let address = account.address
        switch fee.model {
        case .evmEIP1559, .evmLegacy:
            let rpc = try SendEVMRPCClient(networkID: draft.asset.networkID)
            async let identity = rpc.chainID()
            async let balance = rpc.nativeBalance(address: address)
            let (id, amount) = try await (identity, balance)
            guard try SendAtomicAmount.decimalFromHexQuantity(id)
                    == String(ReceiveNetworkCatalog.network(for: draft.asset.networkID)?.chainID ?? 0) else {
                throw SendTransactionSubmissionError.provider(networkID: draft.asset.networkID,
                    code: "chain_id_mismatch", message: WalletLocalization.string("send.submit.error.provider_wrong_chain"))
            }
            return SendReviewNativeBalance(balance: try SendAtomicAmount.decimalFromHexQuantity(amount))
        case .solanaPriority:
            return try await solana(draft: draft, address: address)
        case .tronProtocol:
            return SendReviewNativeBalance(balance: String(try await SendTronAPIClient().accountBalance(address: address)))
        case .tonProtocol:
            let state = try await TONAPIClient.shared.account(address: address)
            guard let balance = ExactDecimalText.canonicalUnsignedInteger(state.balance.text) else {
                throw TONProviderError.invalidResponse("native_balance")
            }
            return SendReviewNativeBalance(balance: balance,
                additionalCost: draft.asset.isNative ? "0" : (fee.secondaryValue ?? "100000000"))
        case .suiProtocol:
            async let objects = SuiAPIClient.shared.coinObjects(address: address, coinType: SuiConstants.nativeCoinType)
            async let pending = database.pendingSendSpendResources(accountID: account.id)
            let (coins, reserved) = try await (objects, pending)
            let available = coins.filter { !reserved.contains(.object($0)) }
            // The current token signer accepts one gas object. A combined
            // balance across smaller objects cannot pay that transaction's budget.
            let balance = draft.asset.isNative
                ? available.reduce("0") { SendAtomicAmount.add($0, String($1.atomicBalance)) }
                : String(available.map(\.atomicBalance).max() ?? 0)
            return SendReviewNativeBalance(balance: balance)
        case .xrpProtocol:
            let api = XRPAPIClient.shared
            async let state = api.optionalAccountState(address: address)
            async let reserve = api.reserveRequirements()
            let (sender, requirements) = try await (state, reserve)
            guard let sender else { return SendReviewNativeBalance(balance: "0") }
            return SendReviewNativeBalance(balance: sender.balanceDrops,
                reserve: String(try requirements.requiredDrops(ownerCount: sender.ownerCount)))
        case .stellarProtocol:
            let api = StellarAPIClient.shared
            async let state = api.accountState(address: address)
            async let network = api.networkState(usingSavedFee: fee.primaryValue)
            let (sender, requirements) = try await (state, network)
            guard let sender else { return SendReviewNativeBalance(balance: "0") }
            let entries = try SendStellarTransactionService.reserveEntries(sender)
            let reserve = try SendAtomicAmount.multiply(requirements.baseReserveStroops, by: UInt64(entries))
            return SendReviewNativeBalance(balance: sender.nativeBalanceStroops,
                reserve: SendAtomicAmount.add(reserve, sender.nativeSellingLiabilitiesStroops))
        case .aptosProtocol:
            return SendReviewNativeBalance(balance: try await AptosAPIClient.shared.nativeBalance(address: address))
        case .nearProtocol:
            let api = NEARAPIClient.shared
            async let account = nearAccount(address: address)
            async let config = api.protocolConfig()
            let (optionalSender, protocolConfig) = try await (account, config)
            guard let sender = optionalSender else { return SendReviewNativeBalance(balance: "0") }
            let reserve = try SendNEARTransactionService.storageReserve(accountState: sender, protocolConfig: protocolConfig)
            var additional = "0"
            if let contract = draft.asset.contractAddress {
                additional = "1" // NEP-141 ft_transfer's attached yoctoNEAR.
                if try await !api.isStorageRegistered(contractID: contract, accountID: draft.recipient) {
                    additional = SendAtomicAmount.add(additional, try await api.storageMinimumBalance(contractID: contract))
                }
            }
            return SendReviewNativeBalance(balance: sender.amount, reserve: reserve, additionalCost: additional)
        case .utxoPerVByte:
            // UTXOs are checked by the transaction planner, never a scalar balance.
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
    }

    private func nearAccount(address: String) async throws -> NEARAccountState? {
        do {
            return try await NEARAPIClient.shared.accountState(accountID: address)
        } catch let error as NEARProviderError {
            // A native deposit initializes an unfunded implicit account. Missing
            // named accounts require account creation, so retain their real error.
            if case .rpc(_, "unknown_account") = error,
               let kind = NEARAddress.kind(address), kind != .named { return nil }
            throw error
        }
    }

    private func solana(draft: SendDraft, address: String) async throws -> SendReviewNativeBalance {
        let rpc = SendSolanaRPCClient()
        guard let state = try await rpc.accountState(address: address) else {
            return SendReviewNativeBalance(balance: "0")
        }
        let rent = try await rpc.minimumBalanceForRentExemption(dataLength: state.dataLength)
        var additional: UInt64 = 0
        if let mint = draft.asset.contractAddress {
            guard let sender = SolanaAddress(string: address), let recipient = SolanaAddress(string: draft.recipient) else {
                throw SendTransactionSubmissionError.invalidRecipient
            }
            let program = try await rpc.tokenProgram(mint: mint)
            let senderToken: String?
            let recipientToken: String?
            switch program {
            case .legacy:
                senderToken = sender.defaultTokenAddress(tokenMintAddress: mint)
                recipientToken = recipient.defaultTokenAddress(tokenMintAddress: mint)
            case .token2022:
                senderToken = sender.token2022Address(tokenMintAddress: mint)
                recipientToken = recipient.token2022Address(tokenMintAddress: mint)
            }
            guard let senderToken, let recipientToken else { throw SendTransactionSubmissionError.unsupportedAsset }
            if try await !rpc.accountExists(address: recipientToken) {
                let length = try await rpc.tokenAccountDataLength(address: senderToken, program: program)
                additional = try await rpc.minimumTokenAccountRent(dataLength: length)
            }
        }
        return SendReviewNativeBalance(balance: String(state.lamports),
            additionalCost: String(additional), solanaRentMinimum: rent)
    }
}
