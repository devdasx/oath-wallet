import Foundation

extension SendTransactionSubmissionService {
    /// Upgrade pre-resource evidence. UTXO/nonce chains require the exact public
    /// transaction, while blockhash/TAPOS chains already have the replay identifier.
    func recoverLegacySpendReservation(
        _ evidence: SendSpendReservationEvidence
    ) async throws -> Bool {
        guard var receipt = evidence.statusReceipt else { return false }
        guard try await !database.pendingSendSubmissionEvidence(accountID: evidence.accountID)
            .contains(where: { $0.reservationID == evidence.reservationID }) else { return false }
        if let chain = BitcoinFamilyChain(rawValue: evidence.networkID) {
            let value = try await BitcoinFamilyElectrumClient.shared.call(
                chain: chain, method: "blockchain.transaction.get",
                params: [AnyEncodable(receipt.transactionHash)], maximumResponseBytes: 8_388_608
            )
            guard let rawHex = value.string else { throw WalletDataStoreError.invalidState }
            receipt.spendResources = try SendSpendResource.bitcoinInputs(
                rawHex: rawHex, transactionID: receipt.transactionHash
            )
        } else if ReceiveNetworkCatalog.network(for: evidence.networkID)?.blockchain.isEVM == true {
            let nonce = try await SendEVMRPCClient(networkID: evidence.networkID).transactionNonce(
                hash: receipt.transactionHash, fromAddress: receipt.fromAddress
            )
            receipt.spendResources = [.sequence(nonce)]
        } else if [SolanaConstants.networkID, TronConstants.networkID].contains(evidence.networkID) {
            receipt.spendResources = [.init(kind: .transactionID, value: WalletDatabase.normalizedSendHash(
                receipt.transactionHash, networkID: evidence.networkID
            ))]
        } else {
            return false
        }
        let reservation = SendSpendReservation(
            reservationID: evidence.reservationID, accountID: evidence.accountID,
            walletID: evidence.walletID, networkID: evidence.networkID, database: database
        )
        try await database.markSendSpendSubmissionStarted(reservation: reservation, receipt: receipt)
        try await database.finishSendSpendSubmission(reservation)
        return true
    }
}
