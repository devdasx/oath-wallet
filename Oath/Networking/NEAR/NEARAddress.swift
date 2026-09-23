import Foundation
import WalletCore

enum NEARAddress {
    enum Kind: Equatable, Sendable {
        case named
        case implicit
        case ethereumImplicit
    }

    static func implicitAddress(publicKey: PublicKey) -> String {
        publicKey.data.map { String(format: "%02x", $0) }.joined()
    }

    static func isValid(_ value: String) -> Bool {
        guard value == value.lowercased(),
              (2...64).contains(value.utf8.count),
              value.first?.isLetter == true || value.first?.isNumber == true,
              value.last?.isLetter == true || value.last?.isNumber == true
        else { return false }
        var previousWasSeparator = false
        for character in value {
            let isAlphanumeric = character.isASCII
                && (character.isLetter || character.isNumber)
            let isSeparator = character == "-"
                || character == "_"
                || character == "."
            guard isAlphanumeric || isSeparator,
                  !(isSeparator && previousWasSeparator)
            else { return false }
            previousWasSeparator = isSeparator
        }
        return true
    }

    static func kind(_ value: String) -> Kind? {
        guard isValid(value) else { return nil }
        if value.utf8.count == 64,
           value.unicodeScalars.allSatisfy(Self.isLowercaseHexDigit) {
            return .implicit
        }
        if value.utf8.count == 42,
           value.hasPrefix("0x"),
           value.dropFirst(2).unicodeScalars.allSatisfy(
               Self.isLowercaseHexDigit
           ) {
            return .ethereumImplicit
        }
        return .named
    }

    private static func isLowercaseHexDigit(
        _ scalar: Unicode.Scalar
    ) -> Bool {
        (48...57).contains(scalar.value)
            || (97...102).contains(scalar.value)
    }

    static func material(
        privateKey: PrivateKey,
        derivationPath: String?
    ) throws -> NEARAccountMaterial {
        let publicKey = privateKey.getPublicKeyEd25519()
        let address = implicitAddress(publicKey: publicKey)
        guard isValid(address) else { throw NEARProviderError.invalidAddress }
        return NEARAccountMaterial(
            address: address,
            publicKey: "ed25519:\(Base58.encodeNoCheck(data: publicKey.data))",
            derivationPath: derivationPath
        )
    }
}
