import Foundation

/// An exchange account can serve many recipients. Its routing memo/tag is
/// part of recipient identity, not optional presentation metadata.
struct SendRecipientIdentity: Hashable, Sendable {
    let address: SendRecipientAddressIdentity
    let memoRecorded: Bool
    private let memoBytes: Data?

    var networkMemo: String? { memoBytes.flatMap { String(data: $0, encoding: .utf8) } }

    // Compare/hash UTF-8 bytes, not Swift String's Unicode canonical equivalence:
    // visually identical text can be different on-chain routing data.
    var memoIdentityKey: String {
        guard memoRecorded else { return "unrecorded" }
        return memoBytes.map { "memo:" + $0.base64EncodedString() } ?? ""
    }

    init?(address: String, networkID: String, memo: String? = nil, memoRecorded: Bool = true) {
        guard let identity = SendRecipientAddressIdentity(address: address, networkID: networkID)
        else { return nil }
        self.address = identity
        self.memoRecorded = memoRecorded || !SendRecipientNetworkMemo.isSupported(networkID)
        if self.memoRecorded {
            do {
                memoBytes = try SendRecipientNetworkMemo.effectiveValue(
                    address: address, networkID: networkID, memo: memo
                ).map { Data($0.utf8) }
            } catch { return nil }
        } else {
            guard memo == nil else { return nil }
            memoBytes = nil
        }
    }
}

/// Mirrors the memo fields actually used by the app's chain signers. Local
/// Notes, request labels/messages and unsupported-chain metadata are not memos.
enum SendRecipientNetworkMemo {
    static func isSupported(_ networkID: String) -> Bool {
        [XRPConstants.networkID, StellarConstants.networkID,
         TONConstants.networkID, SolanaConstants.networkID].contains(networkID)
    }

    static func effectiveValue(address: String, networkID: String, memo: String?) throws -> String? {
        switch networkID {
        case XRPConstants.networkID:
            let explicitTag = try XRPDestinationTag.parsed(memo)
            guard let destination = XRPAddress.resolvedDestination(address: address, explicitTag: explicitTag)
            else { throw SendPaymentRequestError.invalidReference }
            return destination.destinationTag.map { String($0) }
        case StellarConstants.networkID:
            guard let normalized = StellarMemoTextValidator.normalized(memo) else { return nil }
            guard let validated = StellarMemoTextValidator.validated(normalized)
            else { throw SendPaymentRequestError.invalidReference }
            return validated
        case TONConstants.networkID:
            // SendTONTransactionService signs at most 500 characters.
            let comment = String((memo ?? "").prefix(500))
            return comment.isEmpty ? nil : comment
        case SolanaConstants.networkID:
            return memo.flatMap { $0.isEmpty ? nil : $0 }
        default:
            return nil
        }
    }
}
