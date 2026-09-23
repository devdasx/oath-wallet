import Foundation

/// Contains no user input, keys, passwords, paths or provider payloads.
enum BitcoinImportError: Error, Equatable {
    case invalidKey
    case invalidDescriptor
    case checksumMismatch
    case unsupportedScript
    case privateKeyRequired
    case unsupportedNetwork
    case invalidFile
    case fileTooLarge
    case incompleteBackup
    case unsupportedDatabase
    case passwordRequired
    case incorrectPassword
    case unsupportedEncryption
    case noPrivateKeys
}
