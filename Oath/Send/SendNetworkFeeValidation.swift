import Foundation

/// Validate against the quantities the production builders can actually encode.
/// A positive decimal alone is insufficient (for example, XRP 1 drop or a
/// fractional Aptos gas budget cannot be submitted).
enum SendNetworkFeeValidation {
    static let uint256Maximum =
        "115792089237316195423570985008687907853269984665640564039457584007913129639935"

    static func isValid(_ tier: SendNetworkFeeTier, networkID: String) -> Bool {
        guard SendNetworkFeeAPIClient.supportedQuoteNetworkIDs.contains(networkID),
              SendAtomicAmount.isCanonical(tier.primaryValue),
              tier.secondaryValue.map(SendAtomicAmount.isCanonical) ?? true else {
            return false
        }
        let primary = tier.primaryValue
        let secondary = tier.secondaryValue
        if ReceiveNetworkCatalog.network(for: networkID)?.chainID ?? 0 > 0 {
            guard primary != "0", atMost(primary, uint256Maximum) else { return false }
            switch tier.model {
            case .evmEIP1559:
                return secondary.map { atMost($0, primary) } ?? false
            case .evmLegacy:
                return secondary == nil
            default:
                return false
            }
        }
        if BitcoinFamilyChain.allCases.contains(where: { $0.networkID == networkID }) {
            guard tier.model == .utxoPerVByte, secondary == nil,
                  let rate = Int64(primary) else { return false }
            return rate >= Int64(SendNetworkFeeEstimator.minimumUTXORate(networkID: networkID))
        }
        switch networkID {
        case SolanaConstants.networkID:
            return tier.model == .solanaPriority && secondary == nil && UInt64(primary) != nil
        case TronConstants.networkID:
            return tier.model == .tronProtocol && positiveUInt64(primary)
                && secondary.map(positiveUInt64) == true
        case TONConstants.networkID:
            return tier.model == .tonProtocol && positiveUInt64(primary)
                && secondary.map(positiveUInt64) == true
        case SuiConstants.networkID:
            return tier.model == .suiProtocol && positiveUInt64(primary)
                && secondary.map(positiveUInt64) == true
        case XRPConstants.networkID:
            guard tier.model == .xrpProtocol, secondary == nil,
                  let drops = Int64(primary) else { return false }
            return drops >= 10
        case StellarConstants.networkID:
            guard tier.model == .stellarProtocol, secondary == nil,
                  let stroops = UInt32(primary) else { return false }
            return Int64(stroops) >= StellarConstants.minimumFeeStroops
        case AptosConstants.networkID:
            guard tier.model == .aptosProtocol, let budget = UInt64(primary),
                  let secondary, let price = UInt64(secondary), price > 0 else { return false }
            return budget >= price && budget.isMultiple(of: price)
        case NEARConstants.networkID:
            guard tier.model == .nearProtocol, let secondary,
                  secondary != "0",
                  let reserve = try? SendAtomicAmount.multiply(
                    secondary, by: NEARConstants.maximumTransactionGas
                  ) else { return false }
            return primary == reserve
                && atMost(primary, "340282366920938463463374607431768211455")
        default:
            return false
        }
    }

    private static func positiveUInt64(_ value: String) -> Bool {
        UInt64(value).map { $0 > 0 } ?? false
    }

    private static func atMost(_ value: String, _ maximum: String) -> Bool {
        SendAtomicAmount.compare(value, maximum) != .orderedDescending
    }
}
