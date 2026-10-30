import Foundation
import CryptoKit

// MARK: - Public Key

public struct SigningPublicKey: GenericPasswordConvertible, Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawRepresentation == rhs.rawRepresentation
    }

    public init<D>(rawRepresentation data: D) throws where D: ContiguousBytes {
        self.key = try Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    fileprivate let key: Curve25519.Signing.PublicKey

    fileprivate init(publicKey: Curve25519.Signing.PublicKey) {
        self.key = publicKey
    }

    public init(hex: String) throws {
        let data = Data(hex: hex)
        try self.init(rawRepresentation: data)
    }

    public var rawRepresentation: Data {
        key.rawRepresentation
    }

    public var hexRepresentation: String {
        key.rawRepresentation.toHexString()
    }

    public func isValid(signature: Data, for digest: Data) -> Bool {
        return key.isValidSignature(signature, for: digest)
    }

    public var did: String {
        let key = DIDKey(rawData: rawRepresentation)
        return key.did(variant: .ED25519)
    }
}

extension SigningPublicKey: Codable {

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key.rawRepresentation)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let buffer = try container.decode(Data.self)
        try self.init(rawRepresentation: buffer)
    }
}

public struct SigningPrivateKey: GenericPasswordConvertible, Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawRepresentation == rhs.rawRepresentation
    }


    private let key: Curve25519.Signing.PrivateKey

    public init() {
        self.key = Curve25519.Signing.PrivateKey()
    }

    public init<D>(rawRepresentation: D) throws where D: ContiguousBytes {
        self.key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data {
        key.rawRepresentation
    }

    public var publicKey: SigningPublicKey {
        SigningPublicKey(publicKey: key.publicKey)
    }

    public func signature(_ data: Data) throws -> Data {
        return try key.signature(for: data)
    }
}
