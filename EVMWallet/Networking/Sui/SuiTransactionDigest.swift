import Foundation
import WalletCore

enum SuiTransactionDigest {
    static func make(transactionDataBCS: String) throws -> String {
        guard let transactionData = Data(
            base64Encoded: transactionDataBCS
        ) else {
            throw SuiProviderError.invalidResponse(
                "transaction_data_bcs"
            )
        }
        return make(transactionData: transactionData)
    }

    static func make(transactionData: Data) -> String {
        var typedData = Data("TransactionData::".utf8)
        typedData.append(transactionData)
        return Base58.encodeNoCheck(
            data: Hash.blake2b(data: typedData, size: 32)
        )
    }
}
