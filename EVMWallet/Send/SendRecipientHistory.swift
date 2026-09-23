import Foundation
import WalletCore

/// Address identity, not presentation text. In particular, Base58 is case-sensitive
/// and Bitcoin-family aliases must be compared by their locking script.
struct SendRecipientAddressIdentity: Hashable, Sendable {
    let networkID: String
    let value: String

    init?(address: String, networkID: String) {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SendAddressValidator.isValid(address, for: networkID) else { return nil }
        let value: String
        if let chain = BitcoinFamilyChain(rawValue: networkID) {
            if chain == .bitcoin,
               let silentPayment = try? BitcoinSilentPaymentAddress(
                   address
               ) {
                // A BIP352 address has no fixed locking script. The sender
                // derives its one-time Taproot output only after final input
                // selection, so persist the canonical reusable address as a
                // separate identity namespace instead of asking Wallet Core
                // for a script that cannot exist.
                value = "silent-payment:\(silentPayment.encoded)"
            } else {
                let script = BitcoinScript.lockScriptForAddress(
                    address: address,
                    coin: chain.coin
                ).data
                guard !script.isEmpty else { return nil }
                value = script.base64EncodedString()
            }
        } else if SendAddressValidator.evmNetworks.contains(where: { $0.id == networkID }) {
            value = address.lowercased()
        } else {
            switch networkID {
            case TONConstants.networkID:
                guard let raw = TONAddress.rawAddress(from: address) else { return nil }
                value = raw
            case SuiConstants.networkID:
                guard let canonical = SuiCoinType.validatedAccountAddress(address) else { return nil }
                value = canonical
            case AptosConstants.networkID:
                guard let canonical = AptosAddress.canonical(address) else { return nil }
                value = canonical
            case XRPConstants.networkID:
                guard let destination = XRPAddress.resolvedDestination(address: address, explicitTag: nil)
                else { return nil }
                value = destination.classicAddress
            default:
                value = address
            }
        }
        self.networkID = networkID
        self.value = value
    }
}

struct SendRecentRecipient: Identifiable, Equatable, Sendable {
    let id: SendRecipientIdentity
    let address: String
    let sendCount: Int
    let lastSentAt: Date

    var networkMemo: String? { id.networkMemo }

    var memoText: String? {
        guard SendRecipientNetworkMemo.isSupported(id.address.networkID) else { return nil }
        guard id.memoRecorded else { return WalletLocalization.string("send.recipient.history.memo_not_saved") }
        let isXRP = id.address.networkID == XRPConstants.networkID
        if let networkMemo {
            return isXRP
                ? EnglishNumbers.localized("send.recipient.history.destination_tag", networkMemo)
                : EnglishNumbers.localized("send.recipient.history.memo", networkMemo)
        }
        return isXRP
            ? WalletLocalization.string("send.recipient.history.no_destination_tag")
            : WalletLocalization.string("send.recipient.history.no_memo")
    }

    var accessibilityValue: String {
        [memoText, countText].compactMap { $0 }.joined(separator: ". ")
    }

    var countText: String {
        sendCount == 1
            ? WalletLocalization.string("send.recipient.history.sent_once")
            : EnglishNumbers.localized("send.recipient.history.sent_count", EnglishNumbers.integer(Int64(sendCount)))
    }
}

struct SendRecipientHistorySnapshot: Equatable, Sendable {
    let recipientsByIdentity: [SendRecipientIdentity: SendRecentRecipient]
    let recentRecipients: [SendRecentRecipient]

    init(recipientsByIdentity: [SendRecipientIdentity: SendRecentRecipient]) {
        self.recipientsByIdentity = recipientsByIdentity
        recentRecipients = Array(recipientsByIdentity.values.sorted {
            if $0.lastSentAt != $1.lastSentAt { return $0.lastSentAt > $1.lastSentAt }
            if $0.id.address.value != $1.id.address.value { return $0.id.address.value < $1.id.address.value }
            return $0.id.memoIdentityKey < $1.id.memoIdentityKey
        }.prefix(20))
    }

    func assessment(address: String, networkID: String, memo: String? = nil) -> SendRecipientHistoryAssessment? {
        guard let identity = SendRecipientIdentity(address: address, networkID: networkID, memo: memo)
        else { return nil }
        if let recipient = recipientsByIdentity[identity] {
            return .previouslySent(count: recipient.sendCount)
        }
        return .newRecipient
    }
}

enum SendRecipientHistoryAssessment: Equatable {
    case newRecipient
    case previouslySent(count: Int)

    var message: String {
        switch self {
        case .newRecipient:
            WalletLocalization.string("send.recipient.history.first_send")
        case let .previouslySent(count):
            if count == 1 {
                WalletLocalization.string("send.recipient.history.previous_once")
            } else {
                EnglishNumbers.localized("send.recipient.history.previous_count", EnglishNumbers.integer(Int64(count)))
            }
        }
    }
}
