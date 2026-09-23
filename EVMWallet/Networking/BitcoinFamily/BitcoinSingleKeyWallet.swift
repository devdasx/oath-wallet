import Foundation
import GRDB

struct BitcoinSingleKeyWallet: Sendable {
    let format: PrivateKeyImportFormat
    let addresses: [BitcoinHDDerivedAddress]
    var importedMaterial: BitcoinImportedWalletMaterial? = nil
    var importedReceiveAddresses: [BitcoinHDDerivedAddress] = []

    var defaultAddressType: BitcoinHDAddressType {
        importedReceiveAddresses.first?.addressType ?? (format == .wifCompressed ? .bip84 : .bip44)
    }

    func address(
        for type: BitcoinHDAddressType
    ) -> BitcoinHDDerivedAddress? {
        importedReceiveAddresses.first { $0.addressType == type } ?? addresses.first { $0.addressType == type }
    }
}

extension WalletDatabase {
    /// Loads the imported WIF from Keychain and verifies every public address
    /// against the persisted primary Bitcoin account. No private key or WIF is
    /// duplicated into GRDB; the address set is deterministic and inexpensive
    /// to recreate from the protected key.
    func bitcoinSingleKeyWallet(
        walletID: String,
        vault: WalletSecretVault = .shared
    ) async throws -> BitcoinSingleKeyWallet? {
        let stored = try await pool.read { database in
            (
                wallet: try DBWalletRecord.fetchOne(
                    database,
                    key: walletID
                ),
                account: try DBWalletAccountRecord
                    .filter(Column("walletID") == walletID)
                    .filter(Column("networkID") == "bitcoin")
                    .filter(Column("isEnabled") == true)
                    .fetchOne(database)
            )
        }
        if stored.account?.derivationPath == BitcoinImportedWalletMaterial.accountMarker,
           let material = try await bitcoinImportedMaterial(walletID: walletID, vault: vault) {
            let addresses = try await bitcoinImportedAddresses(walletID: walletID, material: material)
            var receive: [BitcoinHDDerivedAddress] = []
            var types = Set<BitcoinHDAddressType>()
            for source in material.sources where !source.internalBranch {
                let type = source.descriptor.script.addressType
                if types.insert(type).inserted {
                    receive.append(try await bitcoinImportedReceiveAddress(walletID: walletID, material: material, type: type))
                }
            }
            return BitcoinSingleKeyWallet(format: .wifCompressed, addresses: addresses,
                importedMaterial: material, importedReceiveAddresses: receive)
        }
        guard let wallet = stored.wallet,
              wallet.kind == DatabaseWalletKind.importedPrivateKey.rawValue,
              let account = stored.account,
              let format = PrivateKeyImportFormat(
                  accountMarker: account.derivationPath
              ),
              [.wifCompressed, .wifUncompressed].contains(format) else {
            return nil
        }
        let authorization = BitcoinFamilySecretDerivationAuthorization(
            walletID: walletID
        )
        let keyData = try await privateKeyData(
            walletID: walletID,
            authorization: authorization,
            vault: vault
        )
        let addresses = try BitcoinHDDerivationService()
            .singleKeyAddresses(
                privateKeyData: keyData,
                format: format
            )
        let result = BitcoinSingleKeyWallet(
            format: format,
            addresses: addresses
        )
        guard let primary = result.address(for: result.defaultAddressType),
              primary.address == account.address,
              primary.publicKey.hexString.caseInsensitiveCompare(
                  account.publicKey ?? ""
              ) == .orderedSame else {
            throw WalletCreationPersistenceError.invalidDraft
        }

        let selected = try await bitcoinReceiveAddressType(
            walletID: walletID
        )
        let validSelection = result.address(for: selected) != nil
            ? selected : result.defaultAddressType
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            let existing = try DBBitcoinHDPreferenceRecord.fetchOne(
                database,
                key: walletID
            )
            guard existing == nil
                    || existing?.receiveAddressType
                        != validSelection.rawValue
                    || existing?.usesSilentPayments == true else {
                return
            }
            try DBBitcoinHDPreferenceRecord(
                walletID: walletID,
                receiveAddressType: validSelection.rawValue,
                usesSilentPayments: false,
                updatedAt: now
            ).save(database)
        }
        return result
    }

    func setBitcoinSingleKeyReceiveAddressType(
        _ addressType: BitcoinHDAddressType,
        walletID: String,
        vault: WalletSecretVault = .shared
    ) async throws -> BitcoinHDDerivedAddress {
        guard let wallet = try await bitcoinSingleKeyWallet(
            walletID: walletID,
            vault: vault
        ), let address = wallet.address(for: addressType) else {
            throw BitcoinHDWalletDatabaseError.unsupportedWallet
        }
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            try DBBitcoinHDPreferenceRecord(
                walletID: walletID,
                receiveAddressType: addressType.rawValue,
                usesSilentPayments: false,
                updatedAt: now
            ).save(database)
        }
        return address
    }
}

struct BitcoinSingleKeyDiscoveryService: Sendable {
    let database: WalletDatabase
    var electrum: BitcoinFamilyElectrumClient = .shared

    func discover(walletID: String) async throws -> BitcoinHDDiscoveryResult {
        if let material = try await database.bitcoinImportedMaterial(walletID: walletID) {
            return try await BitcoinImportedDiscoveryService(database: database, electrum: electrum)
                .discover(walletID: walletID, material: material)
        }
        return try await discoverBatch(walletID: walletID)
    }

    private func discoverBatch(walletID: String) async throws
        -> BitcoinHDDiscoveryResult {
        guard let wallet = try await database.bitcoinSingleKeyWallet(
            walletID: walletID
        ) else {
            throw BitcoinHDDiscoveryError.unsupportedWallet
        }
        let initial = wallet.addresses.map {
            BitcoinHDAddressState(
                derived: $0,
                isUsed: false,
                isReserved: false,
                confirmedBalanceAtomic: .zero,
                unconfirmedBalanceAtomic: .zero
            )
        }
        let scriptHashes = initial.map(\.derived.scriptHash)
        async let historyValues = electrum.callStringParameterBatch(
            chain: .bitcoin,
            method: "blockchain.scripthash.get_history",
            parameters: scriptHashes,
            maximumResponseBytes:
                BitcoinFamilyElectrumClient.maximumHistoryResponseBytes
        )
        async let balanceValues = electrum.callStringParameterBatch(
            chain: .bitcoin,
            method: "blockchain.scripthash.get_balance",
            parameters: scriptHashes
        )
        let (histories, balances) = try await (
            historyValues,
            balanceValues
        )
        var transactions = Set<BitcoinHDTransactionReference>()
        let states = try BitcoinHDDiscoveryService.parse(
            states: initial,
            histories: histories,
            balances: balances,
            transactions: &transactions
        )
        var balance = BitcoinFamilyAtomicInteger.zero
        for state in states {
            balance = balance.adding(state.balanceAtomic)
        }
        guard !balance.isNegative else {
            throw BitcoinHDDiscoveryError.invalidElectrumResponse
        }
        let preferredType = try await database.bitcoinReceiveAddressType(
            walletID: walletID
        )
        guard let receiveAddress = wallet.address(for: preferredType)
                ?? wallet.address(for: wallet.defaultAddressType) else {
            throw BitcoinHDDiscoveryError.missingReceiveAddress
        }
        return BitcoinHDDiscoveryResult(
            states: states,
            balanceAtomic: balance,
            transactions: transactions.sorted {
                let leftPending = $0.height <= 0
                let rightPending = $1.height <= 0
                if leftPending != rightPending { return leftPending }
                if $0.height != $1.height { return $0.height > $1.height }
                return $0.transactionHash < $1.transactionHash
            },
            receiveAddress: receiveAddress
        )
    }

    func refreshBalances(walletID: String) async throws
        -> BitcoinHDDiscoveryResult {
        try await discover(walletID: walletID)
    }
}
