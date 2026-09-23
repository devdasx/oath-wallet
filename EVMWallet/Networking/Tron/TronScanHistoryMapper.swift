import Foundation

enum TronScanHistoryMapper {
    static func nativeTransfers(
        from records: [TronScanNativeTransfer]
    ) -> [TronHistoryItem] {
        records.compactMap { record in
            guard
                record.confirmed == 1,
                record.revert != 1,
                record.contractType == "TransferContract",
                record.contractResult == "SUCCESS",
                let atomic = try? TronUInt256(
                    decimalText: record.amount
                ),
                let amountText = try? atomic.userUnits(decimals: 6)
            else {
                return nil
            }
            return TronHistoryItem(
                transactionID: record.transactionID,
                timestamp: record.blockTimestamp / 1_000,
                blockNumber: record.block,
                from: record.from,
                to: record.to,
                amountText: amountText,
                rawAmount: atomic.decimalText,
                assetIdentity: "native",
                assetSymbol: "TRX",
                assetName: WalletLocalization.string(
                    "network.tron.name"
                ),
                decimals: 6,
                fee: nil,
                failed: false
            )
        }
    }

    static func tokenTransfers(
        from records: [TronScanTokenTransfer]
    ) throws -> [TronHistoryItem] {
        try records.compactMap { record in
            let identity = record.tokenInfo.identity
                ?? record.contractAddress
            guard
                record.confirmed,
                record.reverted != true,
                record.eventType.caseInsensitiveCompare("transfer")
                    == .orderedSame,
                record.contractResult?.caseInsensitiveCompare("SUCCESS")
                    == .orderedSame,
                TronValueParser.hexAddress(identity) != nil,
                let symbol = record.tokenInfo.symbol,
                !symbol.isEmpty,
                let name = record.tokenInfo.name,
                !name.isEmpty,
                let decimals = record.tokenInfo.decimals
            else {
                return nil
            }
            let atomic = try TronUInt256(
                decimalText: record.atomicAmount
            )
            let amountText = try atomic.userUnits(decimals: decimals)
            return TronHistoryItem(
                transactionID: record.transactionID,
                timestamp: record.blockTimestamp / 1_000,
                blockNumber: record.block,
                from: record.from,
                to: record.to,
                amountText: amountText,
                rawAmount: atomic.decimalText,
                assetIdentity: identity,
                assetSymbol: symbol,
                assetName: name,
                decimals: decimals,
                fee: nil,
                failed: false
            )
        }
    }
}
