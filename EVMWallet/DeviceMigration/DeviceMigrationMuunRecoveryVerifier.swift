import Foundation

extension DeviceMigrationAccountSecretVerifier {
    static func verifyMuunRecovery(
        _ data: Data,
        recordedWordCount: Int?,
        recovery: DBMuunRecoveryWalletRecord,
        addresses: [DBMuunRecoveryAddressRecord],
        accounts: [DBWalletAccountRecord]
    ) throws {
        guard recordedWordCount == nil else {
            throw VerificationFailure(
                reason: .invalidMnemonicWordCount,
                family: .bitcoinFamily
            )
        }
        guard let material = try? MuunRecoveryKeyMaterial.decode(data),
              material.birthdayBlock == recovery.birthdayBlock else {
            throw VerificationFailure(
                reason: .derivationFailed,
                family: .bitcoinFamily
            )
        }
        guard accounts.count == 1,
              let account = accounts.first,
              account.networkID == BitcoinFamilyChain.bitcoin.networkID,
              account.accountIndex == 0,
              account.derivationPath
                == MuunRecoveryKeyMaterial.accountMarker,
              !account.isWatchOnly,
              account.isEnabled else {
            throw VerificationFailure(
                reason: .invalidAccountRole,
                family: .bitcoinFamily
            )
        }
        guard let record = addresses.first(where: {
            $0.address == account.address
        }),
            let version = MuunRecoveryAddressVersion(
                rawValue: record.version
            ),
            let branch = MuunRecoveryAddressBranch(
                rawValue: record.branch
            ),
            version == .v5,
            branch == .external,
            record.contactIndex == -1,
            record.addressIndex >= 0 else {
            throw VerificationFailure(
                reason: .invalidAddress,
                family: .bitcoinFamily
            )
        }

        let derived: MuunRecoveryDerivedAddress
        do {
            derived = try MuunRecoveryAddressFactory.derive(
                material: material,
                version: version,
                branch: branch,
                addressIndex: record.addressIndex
            )
        } catch {
            throw VerificationFailure(
                reason: .derivationFailed,
                family: .bitcoinFamily
            )
        }
        guard record.derivationPath == derived.derivationPath,
              record.address == derived.address,
              record.scriptPubKey == derived.scriptPubKey,
              record.scriptHash == derived.scriptHash else {
            throw VerificationFailure(
                reason: .addressMismatch,
                family: .bitcoinFamily
            )
        }
        try verify(
            DerivedIdentity(
                address: derived.address,
                normalizedAddress: derived.address.lowercased(),
                publicKey: Data(
                    derived.scriptPubKey.dropFirst(2)
                ).hexString
            ),
            matches: account,
            family: .bitcoinFamily
        )
    }
}
