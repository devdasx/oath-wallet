import Foundation

/// Serializes memory-intensive password attempts on an executor separate from UI.
actor BitcoinBIP38Decryptor {
    static let shared = BitcoinBIP38Decryptor()

    func decrypt(_ encoded: String, password: String) throws -> WalletImportDraft {
        try Task.checkCancellation()
        return try BitcoinBIP38.decrypt(encoded, password: password)
    }
}
