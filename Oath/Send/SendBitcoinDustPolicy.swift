import Foundation
import WalletCore

/// Mainnet relay defaults, independent of the user's selected transaction fee rate.
/// Existing inputs are never classified as new change by this policy.
enum SendBitcoinDustPolicy {
    static let dogecoinSoftDust: Int64 = 1_000_000

    static func recipientMinimum(chain: BitcoinFamilyChain, script: Data) -> Int64 {
        if script.first == 0x6a { return 0 } // Unspendable OP_RETURN.
        if chain == .dogecoin { return 100_000 }
        let witness = script.count >= 4 && script.count <= 42
            && (script.first == 0 || (0x51...0x60).contains(script.first ?? 0xff))
            && Int(script[script.index(after: script.startIndex)]) == script.count - 2
        let spendSize = chain != .bitcoinCash && witness ? 67 : 148
        let sizePrefix = script.count < 253 ? 1 : 3
        let multiplier = chain == .litecoin ? 30 : 3
        return Int64((8 + sizePrefix + script.count + spendSize) * multiplier)
    }

    static func changeMinimum(chain: BitcoinFamilyChain, script: Data) -> Int64 {
        // DOGE permits 0.001 DOGE outputs but charges another 0.01 DOGE
        // for each output below 0.01 DOGE. Do not manufacture that change.
        chain == .dogecoin ? dogecoinSoftDust : recipientMinimum(chain: chain, script: script)
    }

    static func bitcoinMinimum(scriptSize: Int) -> Int64 {
        // These selectors accept only P2PKH, P2SH, P2WPKH, P2WSH/P2TR.
        let witness = scriptSize == 22 || scriptSize == 34
        return Int64(8 + 1 + scriptSize + (witness ? 67 : 148)) * 3
    }

    static func recipientSurcharge(chain: BitcoinFamilyChain, amount: Int64) -> Int64 {
        chain == .dogecoin && amount < dogecoinSoftDust ? dogecoinSoftDust : 0
    }

    /// A custom total can increase only by an omitted sub-threshold change
    /// output. The resulting total is included in Review and the signed plan.
    static func allowsFee(_ actual: Int64, budget: Int64, change: Int64, minimumChange: Int64) -> Bool {
        guard budget >= 0, actual >= budget else { return false }
        return actual == budget || (change == 0 && actual - budget < minimumChange)
    }
}

extension SendBitcoinTransactionService {
    /// Review and signing use the same exact output policy. Plan with dust
    /// folding disabled first, so the required fee and leftover are separate.
    static func dustSafePlan(
        input: BitcoinSigningInput,
        chain: BitcoinFamilyChain,
        fee: SendResolvedNetworkFee
    ) throws -> BitcoinTransactionPlan {
        var rawInput = input
        rawInput.fixedDustThreshold = 0
        var plan: BitcoinTransactionPlan = AnySigner.plan(input: rawInput, coin: chain.coin)
        guard plan.error == .ok else { throw planError(plan) }
        let budget = try fee.totalBudgetAtomic.map(SendAtomicAmount.int64)
        let surcharge = SendBitcoinDustPolicy.recipientSurcharge(chain: chain, amount: plan.amount)
        let provisionalFee = plan.fee.addingReportingOverflow(surcharge)
        guard !provisionalFee.overflow else { throw SendTransactionSubmissionError.amountOutOfRange }
        let reservedFee = budget ?? provisionalFee.partialValue
        if !input.useMaxAmount, !input.useMaxUtxo,
           reservedFee > plan.fee, reservedFee - plan.fee > plan.change {
            // Select enough inputs for a custom total or DOGE's recipient
            // surcharge. The temporary reservation is never a signed output.
            let reservedAmount = input.amount.addingReportingOverflow(reservedFee - plan.fee)
            guard !reservedAmount.overflow else { throw SendTransactionSubmissionError.amountOutOfRange }
            rawInput.amount = reservedAmount.partialValue
            plan = AnySigner.plan(input: rawInput, coin: chain.coin)
            guard plan.error == .ok else { throw planError(plan) }
            guard plan.amount >= input.amount else { throw SendTransactionSubmissionError.insufficientAssetBalance }
            plan.change += plan.amount - input.amount
            plan.amount = input.amount
        }
        let recipientScript = BitcoinScript.lockScriptForAddress(address: input.toAddress, coin: chain.coin).data
        let changeScript = BitcoinScript.lockScriptForAddress(address: input.changeAddress, coin: chain.coin).data
        guard !recipientScript.isEmpty, !changeScript.isEmpty else {
            throw SendTransactionSubmissionError.derivedAddressMismatch
        }
        let amountAtBudget = input.useMaxAmount
            ? plan.availableAmount - (budget ?? plan.fee) : plan.amount
        let recipientSurcharge = SendBitcoinDustPolicy.recipientSurcharge(chain: chain, amount: amountAtBudget)
        let required = plan.fee.addingReportingOverflow(recipientSurcharge)
        guard !required.overflow else { throw SendTransactionSubmissionError.amountOutOfRange }
        let target = budget ?? required.partialValue
        guard target >= required.partialValue else {
            throw SendTransactionSubmissionError.feeQuoteUnavailable("custom_fee_budget_below_required")
        }
        let resolved = SendResolvedNetworkFee(model: fee.model, primaryValue: fee.primaryValue,
            secondaryValue: fee.secondaryValue, totalBudgetAtomic: String(target),
            provider: fee.provider, expiresAt: fee.expiresAt)
        return try applyingCustomFeeBudget(resolved, to: plan, usesMaximumBalance: input.useMaxAmount,
            minimumOutput: SendBitcoinDustPolicy.recipientMinimum(chain: chain, script: recipientScript),
            minimumChange: SendBitcoinDustPolicy.changeMinimum(chain: chain, script: changeScript))
    }
}
