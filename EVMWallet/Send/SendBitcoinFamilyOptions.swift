import Foundation

struct SendBitcoinOutpoint: Hashable, Sendable {
    let transactionHash: String
    let outputIndex: Int

    init(transactionHash: String, outputIndex: Int) {
        self.transactionHash = transactionHash.lowercased()
        self.outputIndex = outputIndex
    }

    var id: String {
        "\(transactionHash):\(outputIndex)"
    }

    var wireOutputIndex: UInt32? {
        UInt32(exactly: outputIndex)
    }

    var isValid: Bool {
        transactionHash.utf8.count == 64
            && transactionHash.allSatisfy {
                ($0 >= "0" && $0 <= "9")
                    || ($0 >= "a" && $0 <= "f")
            }
            && wireOutputIndex != nil
    }
}

struct SendBitcoinUTXO: Hashable, Identifiable, Sendable {
    let networkID: String
    let outpoint: SendBitcoinOutpoint
    let valueAtomic: String
    let blockHeight: Int64
    let confirmations: Int64
    let owner: BitcoinHDDerivedAddress?
    let silentPaymentOwner: BitcoinSilentPaymentOutput?
    let muunOwner: MuunRecoveryDerivedAddress?

    init(
        networkID: String,
        outpoint: SendBitcoinOutpoint,
        valueAtomic: String,
        blockHeight: Int64,
        confirmations: Int64,
        owner: BitcoinHDDerivedAddress? = nil,
        silentPaymentOwner: BitcoinSilentPaymentOutput? = nil,
        muunOwner: MuunRecoveryDerivedAddress? = nil
    ) {
        self.networkID = networkID
        self.outpoint = outpoint
        self.valueAtomic = valueAtomic
        self.blockHeight = blockHeight
        self.confirmations = confirmations
        self.owner = owner
        self.silentPaymentOwner = silentPaymentOwner
        self.muunOwner = muunOwner
    }

    var id: String { outpoint.id }

    var isValid: Bool {
        BitcoinFamilyChain(rawValue: networkID) != nil
            && outpoint.isValid
            && SendBitcoinAtomicAmount.isCanonicalPositive(valueAtomic)
            && blockHeight >= 0
            && confirmations >= 0
            && (blockHeight > 0 || confirmations == 0)
            && (owner == nil || owner?.scriptPubKey.isEmpty == false)
            && (silentPaymentOwner == nil
                || silentPaymentOwner?.scriptPubKey.isEmpty == false)
            && (muunOwner == nil
                || muunOwner?.scriptPubKey.isEmpty == false)
            && [owner != nil, silentPaymentOwner != nil, muunOwner != nil]
                .filter { $0 }.count <= 1
    }
}

enum SendBitcoinCoinSelection: Hashable, Sendable {
    case automatic
    case manual([SendBitcoinUTXO])

    var selectedUTXOs: [SendBitcoinUTXO] {
        if case let .manual(outputs) = self { outputs } else { [] }
    }
}

struct SendBitcoinFamilyOptions: Hashable, Sendable {
    let coinSelection: SendBitcoinCoinSelection
    let replaceByFee: Bool
    let opReturnMessage: String?

    init(
        coinSelection: SendBitcoinCoinSelection,
        replaceByFee: Bool,
        opReturnMessage: String? = nil
    ) {
        self.coinSelection = coinSelection
        self.replaceByFee = replaceByFee
        self.opReturnMessage = opReturnMessage
    }

    static let automatic = SendBitcoinFamilyOptions(
        coinSelection: .automatic,
        replaceByFee: false
    )

    func replacingCoinSelection(
        _ coinSelection: SendBitcoinCoinSelection
    ) -> SendBitcoinFamilyOptions {
        SendBitcoinFamilyOptions(
            coinSelection: coinSelection,
            replaceByFee: replaceByFee,
            opReturnMessage: opReturnMessage
        )
    }

    func replacingReplaceByFee(
        _ replaceByFee: Bool,
        chain: BitcoinFamilyChain
    ) -> SendBitcoinFamilyOptions {
        SendBitcoinFamilyOptions(
            coinSelection: coinSelection,
            replaceByFee: chain.supportsReplaceByFee && replaceByFee,
            opReturnMessage: opReturnMessage
        )
    }

    func replacingOPReturnMessage(
        _ message: String?
    ) -> SendBitcoinFamilyOptions {
        SendBitcoinFamilyOptions(
            coinSelection: coinSelection,
            replaceByFee: replaceByFee,
            opReturnMessage: message
        )
    }

    func normalized(
        for chain: BitcoinFamilyChain
    ) throws -> SendBitcoinFamilyOptions {
        let normalizedSelection: SendBitcoinCoinSelection
        switch coinSelection {
        case .automatic:
            normalizedSelection = .automatic
        case let .manual(outputs):
            guard !outputs.isEmpty else {
                throw SendBitcoinFamilyOptionsError.emptySelection
            }
            var identifiers = Set<String>()
            for output in outputs {
                guard
                    output.networkID == chain.networkID,
                    output.isValid
                else {
                    throw SendBitcoinFamilyOptionsError.invalidOutput
                }
                guard identifiers.insert(output.id).inserted else {
                    throw SendBitcoinFamilyOptionsError.duplicateOutput
                }
            }
            normalizedSelection = .manual(
                outputs.sorted(by: SendBitcoinUTXOSorting.precedes)
            )
        }
        return SendBitcoinFamilyOptions(
            coinSelection: normalizedSelection,
            replaceByFee: chain.supportsReplaceByFee && replaceByFee,
            opReturnMessage: try SendBitcoinOPReturn.normalizedMessage(
                opReturnMessage,
                chain: chain
            )
        )
    }

    /// Sequence applied to each selected input by a future transaction builder.
    ///
    /// Both values permit locktime. Only `0xfffffffd` opts into BIP125.
    func inputSequence(for chain: BitcoinFamilyChain) -> UInt32 {
        chain.supportsReplaceByFee && replaceByFee
            ? 0xffff_fffd
            : 0xffff_fffe
    }
}

enum SendBitcoinFamilyOptionsError: Error, Hashable, Sendable {
    case emptySelection
    case invalidOutput
    case duplicateOutput
    case insufficientSelectedValue
    case opReturnUnsupported
    case opReturnTooLarge

    var diagnosticCode: String {
        switch self {
        case .emptySelection: "empty_coin_selection"
        case .invalidOutput: "invalid_selected_utxo"
        case .duplicateOutput: "duplicate_selected_utxo"
        case .insufficientSelectedValue: "insufficient_selected_value"
        case .opReturnUnsupported: "op_return_unsupported"
        case .opReturnTooLarge: "op_return_too_large"
        }
    }

    var localizedMessage: String {
        switch self {
        case .emptySelection:
            WalletLocalization.string(
                "send.coin_control.error.empty_selection"
            )
        case .invalidOutput:
            WalletLocalization.string(
                "send.coin_control.error.invalid_output"
            )
        case .duplicateOutput:
            WalletLocalization.string(
                "send.coin_control.error.duplicate_output"
            )
        case .insufficientSelectedValue:
            WalletLocalization.string(
                "send.coin_control.error.insufficient_value"
            )
        case .opReturnUnsupported:
            WalletLocalization.string(
                "send.bitcoin.op_return.error.unsupported"
            )
        case .opReturnTooLarge:
            EnglishNumbers.localized(
                "send.bitcoin.op_return.error.too_large",
                SendBitcoinOPReturn.maximumPayloadBytes
            )
        }
    }
}

enum SendBitcoinAtomicAmount {
    static func isCanonicalPositive(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 100
            && value.allSatisfy { $0 >= "0" && $0 <= "9" }
            && value.first != "0"
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = canonical(lhs)
        let right = canonical(rhs)
        if left.count != right.count {
            return left.count < right.count
                ? .orderedAscending
                : .orderedDescending
        }
        if left == right { return .orderedSame }
        return left.lexicographicallyPrecedes(right)
            ? .orderedAscending
            : .orderedDescending
    }

    static func sum(_ values: some Sequence<String>) -> String {
        values.reduce("0", add)
    }

    private static func add(_ lhs: String, _ rhs: String) -> String {
        let left = Array(canonical(lhs).utf8.reversed())
        let right = Array(canonical(rhs).utf8.reversed())
        let count = max(left.count, right.count)
        var result: [UInt8] = []
        var carry: UInt8 = 0
        for index in 0..<count {
            let leftDigit = index < left.count ? left[index] - 48 : 0
            let rightDigit = index < right.count ? right[index] - 48 : 0
            let total = leftDigit + rightDigit + carry
            result.append((total % 10) + 48)
            carry = total / 10
        }
        if carry > 0 { result.append(carry + 48) }
        return String(decoding: result.reversed(), as: UTF8.self)
    }

    private static func canonical(_ value: String) -> String {
        let trimmed = value.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }
}

enum SendBitcoinUTXOSorting {
    static func precedes(
        _ lhs: SendBitcoinUTXO,
        _ rhs: SendBitcoinUTXO
    ) -> Bool {
        if lhs.confirmations != rhs.confirmations {
            return lhs.confirmations > rhs.confirmations
        }
        let valueOrder = SendBitcoinAtomicAmount.compare(
            lhs.valueAtomic,
            rhs.valueAtomic
        )
        if valueOrder != .orderedSame {
            return valueOrder == .orderedDescending
        }
        if lhs.outpoint.transactionHash != rhs.outpoint.transactionHash {
            return lhs.outpoint.transactionHash
                < rhs.outpoint.transactionHash
        }
        return lhs.outpoint.outputIndex < rhs.outpoint.outputIndex
    }
}
