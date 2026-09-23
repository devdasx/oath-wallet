import Foundation

enum TronHistoryMapper {
    static func tokenTransfers(
        from records: [TronGridTokenTransfer]
    ) throws -> [TronHistoryItem] {
        try records.compactMap { record in
            guard
                record.type.caseInsensitiveCompare("transfer")
                    == .orderedSame,
                let address = record.tokenInfo.address,
                TronValueParser.hexAddress(address) != nil,
                let symbol = record.tokenInfo.symbol,
                !symbol.isEmpty,
                let name = record.tokenInfo.name,
                !name.isEmpty,
                let decimals = record.tokenInfo.decimals
            else {
                return nil
            }
            do {
                let atomic = try TronUInt256(decimalText: record.value)
                let amountText = try atomic.userUnits(
                    decimals: decimals
                )
                return TronHistoryItem(
                    transactionID: record.transactionID,
                    timestamp: record.blockTimestamp / 1_000,
                    blockNumber: nil,
                    from: record.from,
                    to: record.to,
                    amountText: amountText,
                    rawAmount: atomic.decimalText,
                    assetIdentity: address,
                    assetSymbol: symbol,
                    assetName: name,
                    decimals: decimals,
                    fee: nil,
                    failed: false
                )
            } catch {
                throw error
            }
        }
    }

    static func nativeTransfers(
        from transactions: [TronGridTransaction]
    ) -> [TronHistoryItem] {
        transactions.compactMap { transaction in
            guard let contract = transaction.rawData.contract.first,
                  contract.type == "TransferContract",
                  let from = contract.parameter.value.ownerAddress,
                  let to = contract.parameter.value.toAddress,
                  let rawAmount = contract.parameter.value.amount
            else { return nil }
            let decimals = 6
            guard
                rawAmount >= 0,
                let atomic = try? TronUInt256(
                    decimalText: String(rawAmount)
                ),
                let amountText = try? atomic.userUnits(
                    decimals: decimals
                )
            else {
                return nil
            }
            return TronHistoryItem(
                transactionID: transaction.txID,
                timestamp: transaction.blockTimestamp / 1_000,
                blockNumber: transaction.blockNumber,
                from: from,
                to: to,
                amountText: amountText,
                rawAmount: atomic.decimalText,
                assetIdentity: "native",
                assetSymbol: "TRX",
                assetName: WalletLocalization.string(
                    "network.tron.name"
                ),
                decimals: decimals,
                fee: transaction.ret?.first?.fee.map {
                    Decimal($0) / TronConstants.sunPerTRX
                },
                failed: transaction.ret?.first?.contractRet != "SUCCESS"
            )
        }
    }
}
