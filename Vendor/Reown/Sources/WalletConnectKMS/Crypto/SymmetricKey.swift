import Foundation
import CryptoKit

public struct SymmetricKey: Equatable {

    private let key: CryptoKit.SymmetricKey

    public var hexRepresentation: String {
        rawRepresentation.toHexString()
    }

    public enum Errors: Error { case invalidLength }

    public init(key: CryptoKit.SymmetricKey) throws {
        guard key.bitCount == 256 else { throw Errors.invalidLength }
        self.key = key
    }

    public init(size: Size = .bits256) {
        switch size {
        case .bits256:
            self.key = CryptoKit.SymmetricKey(size: SymmetricKeySize.bits256)
        }
    }

    public init(hex: String) throws {
        let data = try Data(validatingHex: hex)
        try self.init(rawRepresentation: data)
    }

    public func derivedTopic() -> String {
        rawRepresentation.sha256().toHexString()
    }

}

extension SymmetricKey: GenericPasswordConvertible {

    public var rawRepresentation: Data {
        key.withUnsafeBytes {Data(Array($0))}
    }

    public init<D>(rawRepresentation data: D) throws where D: ContiguousBytes {
        guard data.withUnsafeBytes({ $0.count }) == 32 else { throw Errors.invalidLength }
        self.key = CryptoKit.SymmetricKey(data: data)
    }
}

extension SymmetricKey {
    public enum Size {
        case bits256
    }
}
