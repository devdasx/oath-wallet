import Foundation
import WalletCore

struct SendBitcoinCoinControlOutputPresentation: Identifiable, Sendable {
    let id: String
    let localAmount: String
    let nativeAmount: String
    let confirmation: String
    let addressType: String?

    init(
        output: SendBitcoinUTXO,
        asset: SendAssetChoice,
        unitUSDPrice: Decimal?,
        currency: WalletCurrencyContext,
        accountAddress: String? = nil
    ) {
        id = output.id
        addressType = Self.addressType(output: output, accountAddress: accountAddress)
        let userUnits = SendDecimalAmount.userUnits(
            fromAtomicUnits: output.valueAtomic,
            decimals: asset.decimals
        )
        localAmount = Self.localAmount(
            userUnits: userUnits,
            unitUSDPrice: unitUSDPrice,
            currency: currency
        )
        nativeAmount = EnglishNumbers.localized(
            "wallet.format.asset_amount",
            userUnits,
            asset.symbol
        )
        confirmation = output.confirmations > 0
            ? EnglishNumbers.localized(
                "send.coin_control.confirmations",
                output.confirmations
            )
            : WalletLocalization.string(
                "send.coin_control.unconfirmed"
            )
    }

    static func addressType(output: SendBitcoinUTXO, accountAddress: String?) -> String? {
        if output.silentPaymentOwner != nil {
            return WalletLocalization.string("receive.bitcoin.address_type.silent_payments")
        }
        if let owner = output.owner {
            if owner.addressType == .bip86, owner.derivationPath.hasPrefix("bitcoin-import:") {
                return WalletLocalization.string("receive.bitcoin.address_type.rawtr")
            }
            return owner.addressType.localizedName
        }
        let script: Data
        if let owner = output.muunOwner {
            script = owner.scriptPubKey
        } else if let address = accountAddress,
                  let chain = BitcoinFamilyChain(rawValue: output.networkID) {
            script = BitcoinScript.lockScriptForAddress(address: address, coin: chain.coin).data
        } else {
            return nil
        }
        let bytes = [UInt8](script)
        let format: String?
        if bytes.count == 25, bytes.prefix(3) == [0x76, 0xa9, 0x14] { format = "P2PKH" }
        else if bytes.count == 23, bytes.prefix(2) == [0xa9, 0x14] { format = "P2SH" }
        else if bytes.count == 22, bytes.prefix(2) == [0x00, 0x14] { format = "P2WPKH" }
        else if bytes.count == 34, bytes.prefix(2) == [0x00, 0x20] { format = "P2WSH" }
        else if bytes.count == 34, bytes.prefix(2) == [0x51, 0x20] { format = "P2TR" }
        else { format = nil }
        return format.map { output.muunOwner == nil ? $0 : "Muun · \($0)" }
    }

    private static func localAmount(
        userUnits: String,
        unitUSDPrice: Decimal?,
        currency: WalletCurrencyContext,
        accountAddress: String? = nil
    ) -> String {
        guard
            currency.ratePerUSD > 0,
            let unitUSDPrice,
            unitUSDPrice > 0,
            let amount = Decimal(
                string: userUnits,
                locale: Locale(identifier: "en_US_POSIX")
            ),
            let usdValue = product(amount, unitUSDPrice)
        else {
            return EnglishNumbers.currency(0, using: currency)
        }
        return EnglishNumbers.currency(
            usdValue,
            using: currency
        )
    }

    private static func product(
        _ lhs: Decimal,
        _ rhs: Decimal
    ) -> Decimal? {
        var left = lhs
        var right = rhs
        var result = Decimal()
        let error = NSDecimalMultiply(
            &result,
            &left,
            &right,
            .plain
        )
        switch error {
        case .noError, .lossOfPrecision, .underflow:
            guard !NSDecimalIsNotANumber(&result), result >= 0 else {
                return nil
            }
            return result
        case .overflow, .divideByZero:
            return nil
        @unknown default:
            return nil
        }
    }
}
