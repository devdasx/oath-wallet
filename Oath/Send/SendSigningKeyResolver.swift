import Foundation
import WalletCore

struct SendSigningKeyResolver: Sendable {
    let database: WalletDatabase
    let dataStore: WalletDataStore

    init(
        database: WalletDatabase,
        dataStore: WalletDataStore? = nil
    ) {
        self.database = database
        self.dataStore = dataStore ?? WalletDataStore(database: database)
    }

    func resolve(
        draft: SendDraft,
        authorization: SendTransactionAuthorization
    ) async throws -> SendResolvedSigningMaterial {
        guard let identity = try await database.selectedWalletIdentity()
        else {
            throw SendTransactionSubmissionError.walletUnavailable
        }
        if try await database.confirmedTronCheck(walletID: identity.walletID) != nil {
            throw SendTransactionSubmissionError.provider(
                networkID: TronConstants.networkID,
                code: "multisig_wallet_restricted",
                message: WalletLocalization.string("tron.permissions.warning.body")
            )
        }
        let accounts = try await dataStore.accounts(
            walletID: identity.walletID
        )
        guard let account = try await SendSigningAccountSelector
            .matchingOwnedAccount(
                in: accounts,
                draft: draft,
                walletID: identity.walletID,
                database: database
            ) else {
            throw SendTransactionSubmissionError.accountUnavailable
        }
        guard !account.isWatchOnly else {
            throw SendTransactionSubmissionError.watchOnlyAccount
        }

        let secretAuthorization: WalletSecretExportAuthorization
        do {
            secretAuthorization = try await authorization.consume(
                reviewedDraft: draft,
                walletID: identity.walletID,
                accountID: account.id,
                networkID: draft.asset.networkID
            )
        } catch {
            throw SendTransactionSubmissionError.authorizationExpired
        }

        if draft.asset.networkID == BitcoinFamilyChain.bitcoin.networkID,
           account.derivationPath == BitcoinImportedWalletMaterial.accountMarker {
            guard let imported = try await database.bitcoinImportedMaterial(walletID: identity.walletID) else {
                throw SendTransactionSubmissionError.secretUnavailable
            }
            let primary = try imported.primaryAddress()
            guard primary.address == account.address else { throw SendTransactionSubmissionError.derivedAddressMismatch }
            return SendResolvedSigningMaterial(walletID: identity.walletID, account: account,
                privateKey: try imported.privateKey(path: primary.derivationPath), bitcoinImportedMaterial: imported)
        }

        if draft.asset.networkID == BitcoinFamilyChain.bitcoin.networkID,
           account.derivationPath
            == MuunRecoveryKeyMaterial.accountMarker {
            let muunMaterial: MuunRecoveryKeyMaterial
            let fresh: MuunRecoveryDerivedAddress
            do {
                muunMaterial = try await database.muunRecoveryKeyMaterial(
                    walletID: identity.walletID
                )
                guard let address = try await database
                    .freshMuunRecoveryReceiveAddress(
                        walletID: identity.walletID
                    ) else {
                    throw SendTransactionSubmissionError
                        .accountUnavailable
                }
                fresh = address
            } catch let error as SendTransactionSubmissionError {
                throw error
            } catch {
                throw SendTransactionSubmissionError.secretUnavailable
            }
            guard fresh.address == account.address,
                  account.normalizedAddress == fresh.address.lowercased(),
                  account.publicKey
                    == Data(fresh.scriptPubKey.dropFirst(2)).hexString else {
                throw SendTransactionSubmissionError
                    .derivedAddressMismatch
            }
            return SendResolvedSigningMaterial(
                walletID: identity.walletID,
                account: account,
                privateKey: muunMaterial.userPrivateKey,
                muunRecoveryKeyMaterial: muunMaterial
            )
        }

        let material: WalletSensitiveMaterial
        do {
            material = try await database.sensitiveMaterial(
                walletID: identity.walletID,
                authorization: secretAuthorization
            )
        } catch {
            guard secretAuthorization.permits(
                walletID: identity.walletID
            ) else {
                throw SendTransactionSubmissionError.authorizationExpired
            }
            throw SendTransactionSubmissionError.secretUnavailable
        }

        let key: PrivateKey
        let bitcoinHDRecoveryCredential: WalletRecoveryCredential?
        switch material {
        case .bitcoinImportedWallet:
            throw SendTransactionSubmissionError.derivedAddressMismatch
        case let .recoveryPhrase(credential):
            key = try recoveryPhraseKey(
                credential,
                account: account,
                networkID: draft.asset.networkID
            )
            bitcoinHDRecoveryCredential = BitcoinFamilyChain(rawValue: draft.asset.networkID) != nil
                ? credential : nil
        case let .privateKey(hexadecimal):
            guard let data = Data(hexString: hexadecimal),
                  data.count == 32,
                  let privateKey = PrivateKey(data: data)
            else {
                throw SendTransactionSubmissionError.secretUnavailable
            }
            key = privateKey
            bitcoinHDRecoveryCredential = nil
        }

        try verify(
            privateKey: key,
            account: account,
            networkID: draft.asset.networkID,
            bitcoinHDRecoveryCredential: bitcoinHDRecoveryCredential,
            isImportedPrivateKey: {
                if case .privateKey = material { return true }
                return false
            }()
        )
        return SendResolvedSigningMaterial(
            walletID: identity.walletID,
            account: account,
            privateKey: key.data,
            bitcoinHDRecoveryCredential: bitcoinHDRecoveryCredential
        )
    }

    private func recoveryPhraseKey(
        _ credential: WalletRecoveryCredential,
        account: DBWalletAccountRecord,
        networkID: String
    ) throws -> PrivateKey {
        if networkID == BitcoinFamilyChain.bitcoin.networkID,
           let location = account.derivationPath.flatMap(
               { BitcoinHDAddressType.location(for: $0, address: account.address, credential: credential) }
           ) {
            return try BitcoinHDDerivationService().privateKey(
                credential: credential,
                addressType: location.addressType,
                branch: location.branch,
                index: location.index
            )
        }
        guard let wallet = credential.makeHDWallet()
        else {
            throw SendTransactionSubmissionError.secretUnavailable
        }
        if let chain = BitcoinFamilyChain(rawValue: networkID) {
            return try requiredRecoveryPhraseKey(
                wallet: wallet,
                coin: chain.coin,
                derivationPath: derivationPath(
                    account.derivationPath,
                    fallback: chain.derivationPath
                )
            )
        }
        if networkID == SolanaConstants.networkID {
            return try requiredRecoveryPhraseKey(
                wallet: wallet,
                coin: .solana,
                derivationPath: derivationPath(
                    account.derivationPath,
                    fallback: SolanaDerivationKind.phantom.derivationPath
                )
            )
        }
        if networkID == TronConstants.networkID {
            return try requiredRecoveryPhraseKey(
                wallet: wallet,
                coin: .tron,
                derivationPath: derivationPath(
                    account.derivationPath,
                    fallback: CoinType.tron.derivationPath()
                )
            )
        }
        if networkID == TONConstants.networkID {
            return try requiredRecoveryPhraseKey(
                wallet: wallet,
                coin: .ton,
                derivationPath: derivationPath(
                    account.derivationPath,
                    fallback: TONConstants.derivationPath
                )
            )
        }
        if networkID == SuiConstants.networkID {
            return try requiredRecoveryPhraseKey(
                wallet: wallet,
                coin: .sui,
                derivationPath: derivationPath(
                    account.derivationPath,
                    fallback: SuiConstants.derivationPath
                )
            )
        }
        if networkID == XRPConstants.networkID {
            return try requiredRecoveryPhraseKey(
                wallet: wallet,
                coin: .xrp,
                derivationPath: derivationPath(
                    account.derivationPath,
                    fallback: XRPConstants.derivationPath
                )
            )
        }
        if networkID == NEARConstants.networkID {
            return try requiredRecoveryPhraseKey(
                wallet: wallet,
                coin: .near,
                derivationPath: derivationPath(
                    account.derivationPath,
                    fallback: NEARConstants.derivationPath
                )
            )
        }
        if networkID == AptosConstants.networkID {
            return wallet.getKeyForCoin(coin: .aptos)
        }
        if networkID == StellarConstants.networkID {
            return try requiredRecoveryPhraseKey(
                wallet: wallet,
                coin: .stellar,
                derivationPath: derivationPath(
                    account.derivationPath,
                    fallback: StellarConstants.derivationPath
                )
            )
        }
        guard ReceiveNetworkCatalog.network(for: networkID)?.chainID ?? 0 > 0
        else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }
        return try requiredRecoveryPhraseKey(
            wallet: wallet,
            coin: .ethereum,
            derivationPath: derivationPath(
                account.derivationPath,
                fallback: CoinType.ethereum.derivationPath()
            )
        )
    }

    private func requiredRecoveryPhraseKey(
        wallet: HDWallet,
        coin: CoinType,
        derivationPath: String
    ) throws -> PrivateKey {
        guard let key = wallet.getKey(
            coin: coin,
            derivationPath: derivationPath
        ) else {
            throw SendTransactionSubmissionError.secretUnavailable
        }
        return key
    }

    private func verify(
        privateKey: PrivateKey,
        account: DBWalletAccountRecord,
        networkID: String,
        bitcoinHDRecoveryCredential: WalletRecoveryCredential?,
        isImportedPrivateKey: Bool
    ) throws {
        let derived: String
        if let chain = BitcoinFamilyChain(rawValue: networkID) {
            if chain == .bitcoin,
               let credential = bitcoinHDRecoveryCredential {
                guard let location = account.derivationPath.flatMap(
                    { BitcoinHDAddressType.location(for: $0, address: account.address, credential: credential) }
                ) else {
                    throw SendTransactionSubmissionError
                        .derivedAddressMismatch
                }
                let derivation = BitcoinHDDerivationService()
                let child = try derivation.deriveAddress(
                    credential: credential,
                    addressType: location.addressType,
                    branch: location.branch,
                    index: location.index
                )
                let expectedKey = try derivation.privateKey(
                    credential: credential,
                    addressType: location.addressType,
                    branch: location.branch,
                    index: location.index
                )
                guard expectedKey.data == privateKey.data else {
                    throw SendTransactionSubmissionError
                        .derivedAddressMismatch
                }
                derived = child.address
            } else {
                let format = isImportedPrivateKey
                    ? PrivateKeyImportFormat(
                        accountMarker: account.derivationPath
                    ) ?? .wifCompressed
                    : .extendedNativeSegwit
                derived = try BitcoinFamilyDerivationService().derive(
                    privateKey: privateKey.data,
                    chain: chain,
                    format: format,
                    derivationPath: account.derivationPath
                ).address
            }
        } else if networkID == SolanaConstants.networkID {
            derived = CoinType.solana.deriveAddress(privateKey: privateKey)
        } else if networkID == TronConstants.networkID {
            derived = CoinType.tron.deriveAddress(privateKey: privateKey)
        } else if networkID == TONConstants.networkID {
            derived = try TONAddress.material(
                privateKey: privateKey,
                derivationPath: account.derivationPath
            ).address
        } else if networkID == SuiConstants.networkID {
            derived = CoinType.sui.deriveAddress(privateKey: privateKey)
        } else if networkID == XRPConstants.networkID {
            derived = CoinType.xrp.deriveAddress(privateKey: privateKey)
        } else if networkID == NEARConstants.networkID {
            derived = try NEARAddress.material(
                privateKey: privateKey,
                derivationPath: account.derivationPath
            ).address
        } else if networkID == AptosConstants.networkID {
            derived = try AptosAddress.material(
                privateKey: privateKey,
                derivationPath: account.derivationPath
            ).address
        } else if networkID == StellarConstants.networkID {
            derived = try StellarAddress.material(
                privateKey: privateKey,
                derivationPath: account.derivationPath
            ).address
        } else if ReceiveNetworkCatalog.network(for: networkID)?
            .chainID ?? 0 > 0 {
            derived = CoinType.ethereum.deriveAddress(
                privateKey: privateKey
            )
        } else {
            throw SendTransactionSubmissionError.unsupportedNetwork
        }

        guard addressesMatch(
            derived,
            account.address,
            networkID: networkID
        ) else {
            throw SendTransactionSubmissionError
                .derivedAddressMismatch
        }
    }

    private func derivationPath(
        _ candidate: String?,
        fallback: String
    ) -> String {
        guard let candidate, candidate.hasPrefix("m/") else {
            return fallback
        }
        return candidate
    }

    private func addressesMatch(
        _ lhs: String,
        _ rhs: String,
        networkID: String
    ) -> Bool {
        if ReceiveNetworkCatalog.network(for: networkID)?.chainID ?? 0 > 0 {
            return lhs.caseInsensitiveCompare(rhs) == .orderedSame
        }
        if networkID == TronConstants.networkID {
            return TronValueParser.accountAddressData(lhs)
                == TronValueParser.accountAddressData(rhs)
        }
        if networkID == TONConstants.networkID {
            return TONAddress.matches(lhs, rhs)
        }
        if networkID == SuiConstants.networkID {
            return SuiCoinType.canonicalAccountAddress(lhs)
                == SuiCoinType.canonicalAccountAddress(rhs)
        }
        if networkID == XRPConstants.networkID {
            return XRPAddress.validatedClassic(lhs)
                == XRPAddress.validatedClassic(rhs)
        }
        if networkID == NEARConstants.networkID {
            return NEARAddress.isValid(lhs)
                && NEARAddress.isValid(rhs)
                && lhs == rhs
        }
        if networkID == AptosConstants.networkID {
            return AptosAddress.canonical(lhs) == AptosAddress.canonical(rhs)
        }
        if networkID == StellarConstants.networkID {
            return StellarAddress.validated(lhs) == StellarAddress.validated(rhs)
        }
        return lhs == rhs
    }
}

enum SendSigningAccountSelector {

    static func matchingOwnedAccount(
        in accounts: [DBWalletAccountRecord],
        draft: SendDraft,
        walletID: String,
        database: WalletDatabase
    ) async throws -> DBWalletAccountRecord? {
        if let exact = matchingAccount(in: accounts, draft: draft) {
            return exact
        }
        guard draft.asset.networkID
                == BitcoinFamilyChain.bitcoin.networkID,
              let sourceAddress = draft.asset.sourceAddress,
              let bitcoinAccount = eligibleAccounts(
                  in: accounts,
                  networkID: draft.asset.networkID
              ).first else {
            return nil
        }

        let ownsSourceAddress: Bool
        if bitcoinAccount.derivationPath == BitcoinImportedWalletMaterial.accountMarker {
            ownsSourceAddress = try await database.bitcoinImportedWalletOwnsAddress(walletID: walletID, address: sourceAddress)
        } else if bitcoinAccount.derivationPath
            == MuunRecoveryKeyMaterial.accountMarker {
            ownsSourceAddress = try await database
                .muunRecoveryWalletOwnsAddress(
                    walletID: walletID,
                    address: sourceAddress
                )
        } else {
            ownsSourceAddress = try await database
                .bitcoinHDWalletOwnsAddress(
                    walletID: walletID,
                    address: sourceAddress
                )
        }
        guard ownsSourceAddress else { return nil }

        // Bitcoin discovery can advance the account row after a Send draft
        // captures a fresh receive child. Persisted wallet membership is the
        // authoritative binding for that reviewed Bitcoin address.
        return bitcoinAccount
    }

    static func matchingAccount(
        in accounts: [DBWalletAccountRecord],
        draft: SendDraft
    ) -> DBWalletAccountRecord? {
        let eligible = eligibleAccounts(
            in: accounts,
            networkID: draft.asset.networkID
        )
        guard let sourceAddress = draft.asset.sourceAddress else {
            return eligible.first
        }

        let exact = eligible.first {
            addressesMatch(
                $0.address,
                sourceAddress,
                networkID: draft.asset.networkID
            )
        }
        return exact
    }

    private static func eligibleAccounts(
        in accounts: [DBWalletAccountRecord],
        networkID: String
    ) -> [DBWalletAccountRecord] {
        accounts
            .filter {
                $0.isEnabled
                    && !$0.isWatchOnly
                    && $0.networkID == networkID
            }
            .sorted { lhs, rhs in
                let lhsIndex = lhs.accountIndex ?? Int.max
                let rhsIndex = rhs.accountIndex ?? Int.max
                if lhsIndex != rhsIndex {
                    return lhsIndex < rhsIndex
                }
                return lhs.id < rhs.id
            }
    }

    private static func addressesMatch(
        _ lhs: String,
        _ rhs: String,
        networkID: String
    ) -> Bool {
        if ReceiveNetworkCatalog.network(for: networkID)?.chainID ?? 0 > 0 {
            return lhs.caseInsensitiveCompare(rhs) == .orderedSame
        }
        if networkID == TronConstants.networkID {
            return TronValueParser.accountAddressData(lhs)
                == TronValueParser.accountAddressData(rhs)
        }
        if networkID == TONConstants.networkID {
            return TONAddress.matches(lhs, rhs)
        }
        if networkID == SuiConstants.networkID {
            return SuiCoinType.canonicalAccountAddress(lhs)
                == SuiCoinType.canonicalAccountAddress(rhs)
        }
        if networkID == XRPConstants.networkID {
            return XRPAddress.validatedClassic(lhs)
                == XRPAddress.validatedClassic(rhs)
        }
        if networkID == NEARConstants.networkID {
            return NEARAddress.isValid(lhs)
                && NEARAddress.isValid(rhs)
                && lhs == rhs
        }
        if networkID == AptosConstants.networkID {
            return AptosAddress.canonical(lhs) == AptosAddress.canonical(rhs)
        }
        if networkID == StellarConstants.networkID {
            return StellarAddress.validated(lhs) == StellarAddress.validated(rhs)
        }
        return lhs == rhs
    }
}
