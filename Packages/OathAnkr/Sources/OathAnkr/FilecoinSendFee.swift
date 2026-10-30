import Foundation

/// Lotus ComputeGasOutputs: network burn, overestimation burn and tip.
/// eth_getTransactionReceipt rounds this total down when reporting gas price.
enum FilecoinSendFee {
    static func actual(gasUsed: UInt64, gasLimit: UInt64, baseFee: UInt64,
                       feeCap: UInt64, premium: UInt64) throws -> UInt64 {
        guard gasUsed <= gasLimit, gasLimit <= 10_000_000_000, premium <= feeCap else { throw EVMSendError.malformed }
        let reserved = gasLimit.multipliedReportingOverflow(by: feeCap)
        guard !reserved.overflow else { throw EVMSendError.malformed }
        let base = min(baseFee, feeCap), tip = min(premium, feeCap - base)
        let burned: UInt64
        if gasUsed == 0 { burned = gasLimit }
        else {
            let allowance = gasUsed * 11 / 10
            let over = min(gasUsed, gasLimit > allowance ? gasLimit - allowance : 0)
            burned = gasUsed.dividingFullWidth((gasLimit - gasUsed).multipliedFullWidth(by: over)).quotient
        }
        // Each term and their sum are bounded by the checked reservation.
        return (gasUsed + burned) * base + gasLimit * tip
    }
}
