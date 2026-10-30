import Foundation
import WalletCore
import OathBitcoin
import OathAnkr

enum OathContactAddressValidator {
    /// Validate the selected chain, never guess a network from a shared address
    /// format. Preserve the user's encoding/case in storage and when copying.
    static func isValid(_ input: String, networkID: String) -> Bool {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let chain = OathImportChain(rawValue: networkID), !address.isEmpty,
              address.utf8.count <= 256,
              address.utf8.allSatisfy({ (33...126).contains($0) }) else { return false }
        if chain == .bitcoincash || chain == .litecoin || chain == .dogecoin, let network = UTXONetwork(rawValue: chain.rawValue) {
            return (try? BitcoinSendPlan.recipientScript(address, chain: network)) != nil
        }
        if chain == .near { return isNearAccountID(address) }
        if chain == .filecoin, address.hasPrefix("f") { return (try? FilecoinIdentity.ethereum(address)) != nil }
        guard AnyAddress.isValid(string: address, coin: chain.walletCoin) else { return false }
        if chain.isEVM {
            // Wallet Core's generic Ethereum validator only checks the hex
            // payload. A mixed-case address must additionally match EIP-55.
            let hex = String(address.dropFirst(2))
            if hex != hex.lowercased(), hex != hex.uppercased() {
                return AnyAddress(string: address, coin: .ethereum)?.description == address
            }
        }
        return true
    }

    private static func isNearAccountID(_ value: String) -> Bool {
        // NEAR account IDs include named accounts, not only the implicit
        // public-key addresses accepted by this version of Wallet Core.
        guard value != "system", (2...64).contains(value.utf8.count) else { return false }
        var previousWasSeparator = true
        for byte in value.utf8 {
            if (97...122).contains(byte) || (48...57).contains(byte) {
                previousWasSeparator = false
            } else if [UInt8(45), 46, 95].contains(byte), !previousWasSeparator {
                previousWasSeparator = true
            } else { return false }
        }
        return !previousWasSeparator
    }
}
