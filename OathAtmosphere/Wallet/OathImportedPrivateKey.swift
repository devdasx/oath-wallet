import OathDiagnostics
import Foundation
import OathBitcoin

/// Only a rejected draft is expected validation. The same error after decoding
/// indicates an import/storage invariant failure and must remain observable.
enum OathPrivateKeyImportFailureStage {
    case decoding, importing

    func shouldReport(_ error: any Error) -> Bool {
        self != .decoding || (error as? OathWalletError) != .invalidPrivateKey
    }
}

/// Secret material: only keep in the import draft or encrypted vault/backup.
/// Network scope is explicit; importing one key never fabricates an HD wallet.
struct OathImportedPrivateKey: Codable, Equatable, Sendable {
    let bytes: Data
    let networks: [OathImportChain]
    // Nil is the original compressed-key format. These fields live only in
    // authenticated, encrypted vault/backup documents, never the public ledger.
    var compressed: Bool? = nil
    var bitcoinExtendedKey: String? = nil

    var dogecoinExtendedKey: String? = nil
    var bitcoinCashExtendedKey: String? = nil
    var requiresBitcoinCashV2: Bool { networks == [.bitcoincash] && (compressed == false || bitcoinCashExtendedKey != nil) }
    var litecoinExtendedKey: String? = nil
    var requiresLitecoinV2: Bool { networks == [.litecoin] && (compressed == false || litecoinExtendedKey != nil) }
    var requiresDogecoinV2: Bool { networks == [.dogecoin] && (compressed == false || dogecoinExtendedKey != nil) }

    var requiresBitcoinV2: Bool { networks == [.bitcoin] && (compressed == false || bitcoinExtendedKey != nil) }

    var isFullEVMScope: Bool {
        let additions: Set<OathImportChain> = [.fantom,.flare,.somnia,.story,.robinhood,.hyperevm,.monad,.unichain,.celo,.chiliz,.filecoin,.sei,.zerog,.iotex]
        let previous = Set(OathImportChain.allCases.filter(\.isEVM)).subtracting(additions)
        return networks.allSatisfy(\.isEVM) && previous.isSubset(of: Set(networks))
    }

    /// Scalar equality is insufficient for UTXO wallets: compression changes
    /// the address, and a BIP32 chain code changes every descendant. Treat
    /// equivalent extended-key version prefixes as aliases of one wallet.
    func hasSameIdentity(as other: Self) -> Bool {
        guard isValidStructure, other.isValidStructure, bytes == other.bytes,
              (Set(networks) == Set(other.networks) || (isFullEVMScope && other.isFullEVMScope)),
              (compressed != false) == (other.compressed != false) else { return false }
        return sameExtended(bitcoinExtendedKey, other.bitcoinExtendedKey, network: .bitcoin)
            && sameExtended(dogecoinExtendedKey, other.dogecoinExtendedKey, network: .dogecoin)
            && sameExtended(litecoinExtendedKey, other.litecoinExtendedKey, network: .litecoin)
            && sameExtended(bitcoinCashExtendedKey, other.bitcoinCashExtendedKey, network: .bitcoincash)
    }

    private func sameExtended(_ lhs: String?, _ rhs: String?, network: UTXONetwork) -> Bool {
        if lhs == rhs { return true }
        guard let lhs, let rhs else { return false }
        do {
            let left = try network.extended(network.restoredExtendedPrivateKey(lhs, storedScalar: bytes))
            let right = try network.extended(network.restoredExtendedPrivateKey(rhs, storedScalar: bytes))
            return left.branches == right.branches
        } catch { OathDiagnostics.record(error); return false }
    }

    var isValidStructure: Bool {
        bytes.count == 32 && !networks.isEmpty && Set(networks).count == networks.count
            && (compressed != false || networks == [.bitcoin] || networks == [.dogecoin] || networks == [.litecoin] || networks == [.bitcoincash])
            && (bitcoinExtendedKey == nil || (networks == [.bitcoin] && compressed != false && bitcoinExtendedKey!.utf8.count <= 128))
            && (dogecoinExtendedKey == nil || (networks == [.dogecoin] && compressed != false && dogecoinExtendedKey!.utf8.count <= 128))
            && (litecoinExtendedKey == nil || (networks == [.litecoin] && compressed != false && litecoinExtendedKey!.utf8.count <= 128))
            && (bitcoinCashExtendedKey == nil || (networks == [.bitcoincash] && compressed != false && bitcoinCashExtendedKey!.utf8.count <= 128))
            && (networks.allSatisfy(\.isEVM) || networks.count == 1)
    }
}
