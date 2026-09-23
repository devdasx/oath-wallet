import Foundation

enum BitcoinImportErrorPresentation {
    static func message(_ error: Error) -> String {
        let key: String
        switch error as? BitcoinImportError {
        case .unsupportedScript, .unsupportedDatabase, .unsupportedEncryption:
            key = "import.bitcoin.file.unsupported"
        case .privateKeyRequired, .noPrivateKeys:
            key = "import.bitcoin.file.no_private_keys"
        case .incompleteBackup:
            key = "import.bitcoin.file.incomplete"
        case .fileTooLarge:
            key = "import.bitcoin.file.too_large"
        case .unsupportedNetwork:
            key = "import.bitcoin.file.mainnet_only"
        case .incorrectPassword:
            key = "import.bip38.wrong_password"
        default:
            key = "import.bitcoin.file.invalid"
        }
        return WalletLocalization.string(key)
    }
}
