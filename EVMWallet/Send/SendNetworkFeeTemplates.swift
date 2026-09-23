import Foundation

extension SendNetworkFeeEstimator {
    static func templateEstimate(
        draft: SendDraft,
        fee: SendResolvedNetworkFee
    ) throws -> SendNetworkFeeEstimate {
        if draft.asset.networkID == BitcoinFamilyChain.bitcoin.networkID,
           try SendBitcoinOPReturn.payload(for: draft.bitcoinFamilyOptions.opReturnMessage) != nil {
            try SendBitcoinTransactionPolicy.validateVirtualSize(
                Int64(templateUTXOVirtualBytes(draft: draft))
            )
        }
        if let totalBudgetAtomic = fee.totalBudgetAtomic {
            return SendNetworkFeeEstimate(
                atomicAmount: totalBudgetAtomic,
                nativeDecimals: nativeDecimals(for: fee.model),
                source: .transactionTemplate
            )
        }
        let atomicAmount: String
        switch fee.model {
        case .evmEIP1559, .evmLegacy:
            atomicAmount = SendAtomicAmount.add(
                try SendAtomicAmount.multiply(
                    fee.primaryValue, by: templateEVMGasUnits(draft: draft)
                ),
                SendEVMRollupFee.defaultReserve(networkID: draft.asset.networkID)
            )
        case .utxoPerVByte:
            atomicAmount = try SendAtomicAmount.multiply(
                fee.primaryValue,
                by: templateUTXOVirtualBytes(draft: draft)
            )
        case .solanaPriority:
            atomicAmount = try solanaFeeAtomic(draft: draft, fee: fee)
        case .tronProtocol:
            atomicAmount = try templateTronFeeAtomic(
                draft: draft,
                fee: fee
            )
        case .tonProtocol, .suiProtocol, .xrpProtocol,
                .aptosProtocol, .nearProtocol, .stellarProtocol:
            atomicAmount = fee.primaryValue
        }
        return SendNetworkFeeEstimate(
            atomicAmount: atomicAmount,
            nativeDecimals: nativeDecimals(for: fee.model),
            source: .transactionTemplate
        )
    }

    static func templateCostBasis(
        draft: SendDraft,
        model: SendNetworkFeeCustomModel,
        referenceFee: SendResolvedNetworkFee? = nil,
        minimumFee: SendResolvedNetworkFee? = nil
    ) -> SendNetworkFeeCostBasis {
        switch model {
        case .evmEIP1559:
            return .eip1559(
                units: templateEVMGasUnits(draft: draft),
                minimumRate: minimumRate(
                    model: model,
                    fee: minimumFee
                ),
                suggestedPriorityRate: priorityRate(
                    from: referenceFee
                ),
                additionalReserve: SendEVMRollupFee.defaultReserve(
                    networkID: draft.asset.networkID
                )
            )
        case .evmLegacy:
            return .linear(
                units: templateEVMGasUnits(draft: draft),
                minimumRate: minimumRate(
                    model: model,
                    fee: minimumFee
                ),
                additionalReserve: SendEVMRollupFee.defaultReserve(
                    networkID: draft.asset.networkID
                )
            )
        case .utxoPerVByte:
            return .linear(
                units: templateUTXOVirtualBytes(draft: draft),
                minimumRate: minimumUTXORate(
                    networkID: draft.asset.networkID
                )
            )
        case .solanaPriority:
            return .solana(
                computeUnits: draft.asset.isNative
                    ? 200_000 : 400_000,
                baseAtomic: 5_000
            )
        case .tronFeeLimit:
            let estimate = (minimumFee ?? referenceFee).flatMap {
                try? templateEstimate(draft: draft, fee: $0)
            }
            return .direct(
                minimumAtomic: estimate?.atomicAmount ?? "1"
            )
        }
    }

    static func minimumRate(
        model: SendNetworkFeeCustomModel,
        fee: SendResolvedNetworkFee?
    ) -> UInt64 {
        guard let fee,
              fee.model == model.quoteModel,
              let value = UInt64(fee.primaryValue),
              value > 0 else { return 1 }
        return value
    }

    static func priorityRate(
        from fee: SendResolvedNetworkFee?
    ) -> String {
        guard let value = fee?.secondaryValue,
              SendAtomicAmount.isCanonical(value) else {
            return "0"
        }
        return value
    }

    static func templateUTXOVirtualBytes(
        draft: SendDraft
    ) -> UInt64 {
        let inputCount: UInt64
        if case let .manual(outputs) = draft
            .bitcoinFamilyOptions.coinSelection,
           !outputs.isEmpty {
            inputCount = UInt64(outputs.count)
        } else {
            inputCount = 1
        }
        let source = draft.asset.sourceAddress ?? ""
        let inputSize = utxoInputVirtualBytes(address: source)
        let recipientOutput = utxoOutputBytes(address: draft.recipient)
        let changeOutput = draft.usesMaximumBalance
            ? 0 : utxoOutputBytes(address: source)
        let opReturnOutput: UInt64
        if draft.asset.networkID == BitcoinFamilyChain.bitcoin.networkID,
           let script = try? SendBitcoinOPReturn.scriptPubKey(
               for: draft.bitcoinFamilyOptions.opReturnMessage
           ) {
            opReturnOutput = UInt64(SendBitcoinOPReturn.serializedOutputSize(
                scriptBytes: script.count
            ))
        } else {
            opReturnOutput = 0
        }
        let inputs = inputCount.multipliedReportingOverflow(by: inputSize)
        guard !inputs.overflow else { return UInt64.max / 2 }
        return 9 + UInt64(SendBitcoinOPReturn.compactSizeLength(Int(inputCount)))
            + inputs.partialValue + recipientOutput + changeOutput
            + opReturnOutput
    }

    private static func templateEVMGasUnits(
        draft: SendDraft
    ) -> UInt64 {
        // The exact path applies the production 20% gas-limit buffer. These
        // are the same buffered units for a standard native or token transfer.
        draft.asset.isNative ? 25_200 : 78_000
    }

    private static func utxoInputVirtualBytes(
        address: String
    ) -> UInt64 {
        let value = address.lowercased()
        if value.hasPrefix("bc1p") || value.hasPrefix("ltc1p") {
            return 58
        }
        if value.hasPrefix("bc1") || value.hasPrefix("ltc1") {
            return 68
        }
        if address.hasPrefix("3") || address.hasPrefix("M") {
            return 91
        }
        return 148
    }

    private static func utxoOutputBytes(address: String) -> UInt64 {
        let value = address.lowercased()
        if BitcoinSilentPaymentAddress.isValidMainnet(value)
            || value.hasPrefix("bc1p")
            || value.hasPrefix("ltc1p") {
            return 43
        }
        if value.hasPrefix("bc1") || value.hasPrefix("ltc1") {
            return 31
        }
        if address.hasPrefix("3") || address.hasPrefix("M") {
            return 32
        }
        return 34
    }

    static func minimumUTXORate(networkID: String) -> UInt64 {
        networkID == BitcoinFamilyChain.dogecoin.networkID ? 1_000 : 1
    }

    private static func templateTronFeeAtomic(
        draft: SendDraft,
        fee: SendResolvedNetworkFee
    ) throws -> String {
        // A custom TRON value is already a total fee limit in SUN. Automatic
        // quotes contain energy and bandwidth prices and therefore need a
        // representative transfer envelope until exact resource reads finish.
        guard let bandwidthPrice = fee.secondaryValue else {
            return fee.primaryValue
        }
        let bandwidthBytes: UInt64 = draft.asset.isNative ? 300 : 400
        let bandwidth = try SendAtomicAmount.multiply(
            bandwidthPrice,
            by: bandwidthBytes
        )
        guard !draft.asset.isNative else { return bandwidth }
        let energy = try SendAtomicAmount.multiply(
            fee.primaryValue,
            by: 65_000
        )
        return SendAtomicAmount.add(energy, bandwidth)
    }

}
