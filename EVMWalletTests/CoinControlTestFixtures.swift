import Foundation
import Testing
import WalletCore
@testable import Aperture

struct CoinControlTestFixtures {
    let credential: WalletRecoveryCredential
    let inputs: SendBitcoinPlanningInputs
    let asset: SendAssetChoice
    let change: BitcoinHDDerivedAddress
    let recipient: BitcoinHDDerivedAddress

    func draft(amount: String?, maximum: Bool = false, manual: Bool = false) -> SendDraft {
        SendDraft(request: .manualEntry(networkID: "bitcoin"), asset: asset,
            recipient: recipient.address, amount: amount, note: nil,
            bitcoinFamilyOptions: .automatic.replacingCoinSelection(
                manual ? .manual([inputs.outputs[0]]) : .automatic), usesMaximumBalance: maximum)
    }

    static func make(types: [BitcoinHDAddressType] = [.bip44, .bip49, .bip84, .bip86]) throws -> Self {
        let credential = try WalletRecoveryCredential(mnemonic:
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        let wallet = try #require(credential.makeHDWallet())
        let derivation = BitcoinHDDerivationService()
        let owners = try types.enumerated().map { index, type in
            try derivation.deriveAddress(wallet: wallet, addressType: type, branch: .external, index: index)
        }
        let first = try #require(owners.first)
        let outputs = owners.enumerated().map { index, owner in
            SendBitcoinUTXO(networkID: "bitcoin", outpoint: SendBitcoinOutpoint(
                transactionHash: String(repeating: "ab", count: 32), outputIndex: index),
                valueAtomic: String(50_000 - index * 10_000), blockHeight: 800_000,
                confirmations: 10, owner: owner)
        }
        let asset = SendAssetChoice(id: "bitcoin:native", name: "Bitcoin", symbol: "BTC",
            networkID: "bitcoin", networkName: "Bitcoin", blockchain: .bitcoin,
            contractAddress: nil, decimals: 8, logoSource: .nativeCoin(blockchain: .bitcoin),
            networkLogoSource: .network(blockchain: .bitcoin), balance: 1, fiatValue: 60_000,
            balanceAtomic: "100000000", sourceAddress: first.address)
        return Self(credential: credential,
            inputs: SendBitcoinPlanningInputs(walletID: "test-wallet",
                account: account(address: first.address, networkID: "bitcoin",
                    path: first.derivationPath, publicKey: first.publicKey.hexString), outputs: outputs),
            asset: asset,
            change: try derivation.deriveAddress(wallet: wallet, addressType: .bip84, branch: .change, index: 0),
            recipient: try derivation.deriveAddress(wallet: wallet, addressType: .bip84, branch: .external, index: 20))
    }

    static func account(address: String, networkID: String, path: String? = nil,
                        publicKey: String? = nil) -> DBWalletAccountRecord {
        DBWalletAccountRecord(id: "test-wallet:\(networkID):0", walletID: "test-wallet",
            networkID: networkID, address: address, normalizedAddress: address.lowercased(),
            label: nil, derivationPath: path, accountIndex: 0, publicKey: publicKey,
            isWatchOnly: false, isEnabled: true, createdAt: 0, updatedAt: 0, lastSyncedAt: nil)
    }
}
