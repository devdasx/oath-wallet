import Foundation
import OathAnkr

enum OathSendRecipientRules {
    /// A network rule and an existing wallet limitation must not use the same
    /// explanation. This applies only to ordinary Send, never dApp contract
    /// calls, XRPL conversions, or permission-removal transactions.
    enum SelfTransferRestriction: Equatable {
        case network, wallet
        var message: OathStringKey {
            switch self {
            case .network: .sendSelfTransferNetwork
            case .wallet: .sendSelfTransferWallet
            }
        }
    }

    static func selfTransferRestriction(sender: String, recipient: String, chain: OathImportChain,
                                        reference: String) -> SelfTransferRestriction? {
        // Expected local form validation, not an app failure. Never report
        // addresses, invalid partial input, or each keystroke to diagnostics.
        guard let source = account(sender, chain: chain), let destination = account(recipient, chain: chain),
              source == destination else { return nil }
        switch chain {
        case .bitcoin, .bitcoincash, .litecoin, .dogecoin, .sui:
            return nil // Existing send implementations permit self-transfers.
        case .xrpl:
            // Ordinary same-asset Payment without Paths: temREDUNDANT. Tags do
            // not change the ledger account. Cross-currency payments differ.
            // https://xrpl.org/docs/references/protocol/transactions/types/payment
            return .network
        case .tron:
            // java-tron TransferActuator and TransferAssetActuator prohibit
            // TRX/TRC-10 to the sender. TRC-20 is contract-specific, not a
            // blanket network rule; Oath's existing sender guard still applies.
            // https://github.com/tronprotocol/java-tron/tree/develop/actuator/src/main/java/org/tron/core/actuator
            return reference == "native" || TronIdentity.isTRC10(reference) ? .network : .wallet
        case .near:
            // The NEP-141 reference implementation rejects sender==receiver;
            // the protocol itself allows native self-transfers. Custom token
            // contracts can differ, so retain accurate wallet-level wording.
            // https://github.com/near/near-sdk-rs/blob/master/near-contract-standards/src/fungible_token/core_impl.rs
            return .wallet
        case .aptos, .ton, .stellar, .thorchain, .solana,
             .arbitrum, .arc, .avalanche, .base, .bnb, .ethereum, .fantom, .flare, .gnosis,
             .linea, .optimism, .polygon, .monad, .unichain, .hyperevm, .robinhood,
             .scroll, .somnia, .story, .taiko, .telos, .xlayer:
            // These send plans already reject the same sender/recipient. Move
            // their late generic quote failure to Recipient, without claiming
            // that the underlying networks prohibit self-transfers.
            return .wallet
        }
    }

    private static func account(_ input: String, chain: OathImportChain) -> String? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reuse validated scanner decoding: XRP X-addresses become classic
        // accounts, Stellar muxed addresses become G accounts, TRON hex becomes
        // Base58. Never lowercase case-sensitive Base58 addresses.
        guard let decoded = OathScanAddress.decode(input, chain: chain) else { return nil }
        if chain.isEVM { return decoded.address.lowercased() }
        switch chain {
        case .ton: return try? TonIdentity.raw(decoded.address)
        case .aptos, .sui: return try? AptosIdentity.address(decoded.address)
        default: return decoded.address
        }
    }

    static func validMemo(_ value: String, networkID: String) -> Bool {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        switch networkID {
        case "thorchain": return value.utf8.count <= 250 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        case "xrpl": return value.isEmpty || (value.utf8.allSatisfy { (48...57).contains($0) } && UInt32(value) != nil)
        case "stellar": return value.utf8.count <= 28
        case "solana": return value.utf8.count <= 128
        case "ton": return value.utf8.count <= 120
        default: return value.isEmpty
        }
    }
}
