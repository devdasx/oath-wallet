import Foundation
import GRDB
import WalletCore

struct BitcoinSilentPaymentPrivateKeyExportEntry: Sendable {
    let output: BitcoinSilentPaymentOutput
    let descriptor: String
}

extension WalletDatabase {
    /// Export only unspent outputs, retaining the final Taproot output-key policy.
    func bitcoinSilentPaymentPrivateKeyExportEntries(
        walletID: String,
        authorization: WalletSecretExportAuthorization,
        vault: WalletSecretVault = .shared
    ) async throws -> [BitcoinSilentPaymentPrivateKeyExportEntry] {
        guard authorization.permits(walletID: walletID) else {
            throw WalletSecretExportAuthorizationError.authenticationRequired
        }
        let outputs = try await bitcoinSilentPaymentOutputs(walletID: walletID, unspentOnly: true)
        var entries: [BitcoinSilentPaymentPrivateKeyExportEntry] = []
        for output in outputs {
            let descriptor = try await bitcoinSilentPaymentOutputDescriptorForExport(
                walletID: walletID, transactionHash: output.transactionHash,
                outputIndex: output.outputIndex, authorization: authorization, vault: vault
            )
            entries.append(.init(output: output, descriptor: descriptor))
        }
        return entries
    }

    func bitcoinSilentPaymentOutputDescriptorForExport(
        walletID: String, transactionHash: String, outputIndex: Int,
        authorization: WalletSecretExportAuthorization,
        vault: WalletSecretVault = .shared
    ) async throws -> String {
        let bytes = try await bitcoinSilentPaymentOutputPrivateKeyForExport(
            walletID: walletID, transactionHash: transactionHash, outputIndex: outputIndex,
            authorization: authorization, vault: vault
        )
        guard let privateKey = PrivateKey(data: bytes),
              let output = try await pool.read({ database in
                  try DBBitcoinSilentPaymentOutputRecord.fetchOne(database, key: [
                      "walletID": walletID, "transactionHash": transactionHash.lowercased(), "outputIndex": outputIndex,
                  ])
              }), !output.isSpent else {
            throw BitcoinSilentPaymentDatabaseError.invalidOutput
        }
        let body = "rawtr(\(BitcoinHDDerivationService.bitcoinWIF(privateKey: privateKey)))"
        let descriptor = body + "#" + (try BitcoinDescriptorChecksum.checksum(body))
        let derived = try BitcoinPrivateDescriptor(descriptor).address()
        guard derived.scriptPubKey == output.scriptPubKey,
              Data(derived.scriptPubKey.suffix(32)) == output.outputPublicKey else {
            throw BitcoinSilentPaymentDatabaseError.invalidOutput
        }
        return descriptor
    }
}
