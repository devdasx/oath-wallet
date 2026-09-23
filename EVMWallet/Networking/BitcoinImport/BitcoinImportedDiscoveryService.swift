import Foundation

struct BitcoinImportedDiscoveryService: Sendable {
    let database: WalletDatabase
    let electrum: BitcoinFamilyElectrumClient

    func discover(walletID: String, material: BitcoinImportedWalletMaterial) async throws -> BitcoinHDDiscoveryResult {
        var states: [String: BitcoinHDAddressState] = [:]
        var transactions = Set<BitcoinHDTransactionReference>()
        var includesExisting = true
        while true {
            try Task.checkCancellation()
            let before = try await database.bitcoinImportedAddressCount(walletID: walletID)
            let addresses = try await database.bitcoinImportedAddresses(walletID: walletID, material: material, includesExisting: includesExisting)
            includesExisting = false
            let fresh = addresses.filter { states[$0.scriptHash] == nil }
            // Newly derived aliases may share a script already fetched through
            // a fixed key. Carry its known usage into every new source row.
            var newlyUsed = addresses.compactMap { states[$0.scriptHash] }.filter(\.isUsed)
            // Bound each transport batch independently of the backup's total size.
            for offset in stride(from: 0, to: fresh.count, by: 100) {
                let batch = Array(fresh[offset..<min(offset + 100, fresh.count)])
                let initial = batch.map { BitcoinHDAddressState(derived: $0, isUsed: false, isReserved: false,
                    confirmedBalanceAtomic: .zero, unconfirmedBalanceAtomic: .zero) }
                async let history = electrum.callStringParameterBatch(chain: .bitcoin,
                    method: "blockchain.scripthash.get_history", parameters: batch.map(\.scriptHash),
                    maximumResponseBytes: BitcoinFamilyElectrumClient.maximumHistoryResponseBytes)
                async let balance = electrum.callStringParameterBatch(chain: .bitcoin,
                    method: "blockchain.scripthash.get_balance", parameters: batch.map(\.scriptHash))
                let (histories, balances) = try await (history, balance)
                let parsed = try BitcoinHDDiscoveryService.parse(states: initial, histories: histories,
                    balances: balances, transactions: &transactions)
                for state in parsed { states[state.derived.scriptHash] = state }
                newlyUsed += parsed.filter(\.isUsed)
            }
            try await database.markBitcoinImportedUsage(walletID: walletID, states: newlyUsed)
            let after = try await database.bitcoinImportedAddressCount(walletID: walletID)
            // A newly used boundary can require another gap batch even when this
            // iteration did not add addresses. Query one more batch in that case.
            if after == before, fresh.isEmpty { break }
        }
        var total = BitcoinFamilyAtomicInteger.zero
        for state in states.values { total = total.adding(state.balanceAtomic) }
        guard !total.isNegative else { throw BitcoinHDDiscoveryError.invalidElectrumResponse }
        let type = try await database.bitcoinReceiveAddressType(walletID: walletID)
        let receive = try await database.bitcoinImportedReceiveAddress(walletID: walletID, material: material, type: type)
        return BitcoinHDDiscoveryResult(states: states.values.sorted { $0.derived.derivationPath < $1.derived.derivationPath },
            balanceAtomic: total, transactions: transactions.sorted {
                if ($0.height <= 0) != ($1.height <= 0) { return $0.height <= 0 }
                if $0.height != $1.height { return $0.height > $1.height }
                return $0.transactionHash < $1.transactionHash
            }, receiveAddress: receive)
    }
}
