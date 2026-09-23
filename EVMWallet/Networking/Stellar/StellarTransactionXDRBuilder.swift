import CryptoKit
import Foundation

enum StellarTransactionOperation: Sendable {
    case createAccount(destination: String, amountStroops: Int64)
    case payment(
        destination: String,
        asset: StellarAssetIdentity?,
        amountStroops: Int64
    )
}

struct StellarSignedTransaction: Sendable {
    let envelopeXDR: String
    let transactionHash: String
}

enum StellarTransactionXDRBuilderError: Error, Sendable {
    case invalidAddress
    case invalidPrivateKey
    case sourceAccountMismatch
    case invalidFee
    case invalidSequence
    case invalidAmount
    case invalidMemo
    case invalidAsset

    var diagnosticCode: String {
        switch self {
        case .invalidAddress: "stellar_xdr_invalid_address"
        case .invalidPrivateKey: "stellar_xdr_invalid_private_key"
        case .sourceAccountMismatch: "stellar_xdr_source_mismatch"
        case .invalidFee: "stellar_xdr_invalid_fee"
        case .invalidSequence: "stellar_xdr_invalid_sequence"
        case .invalidAmount: "stellar_xdr_invalid_amount"
        case .invalidMemo: "stellar_xdr_invalid_memo"
        case .invalidAsset: "stellar_xdr_invalid_asset"
        }
    }
}

enum StellarTransactionXDRBuilder {
    private static let envelopeTypeTransaction: Int32 = 2
    private static let publicKeyTypeEd25519: Int32 = 0

    static func signedEnvelope(
        source: String,
        sequence: Int64,
        feeStroops: Int64,
        memo: String?,
        operation: StellarTransactionOperation,
        privateKeyData: Data
    ) throws -> String {
        try signedTransaction(
            source: source,
            sequence: sequence,
            feeStroops: feeStroops,
            memo: memo,
            operation: operation,
            privateKeyData: privateKeyData
        ).envelopeXDR
    }

    static func signedTransaction(
        source: String,
        sequence: Int64,
        feeStroops: Int64,
        memo: String?,
        operation: StellarTransactionOperation,
        privateKeyData: Data
    ) throws -> StellarSignedTransaction {
        guard sequence > 0 else {
            throw StellarTransactionXDRBuilderError.invalidSequence
        }
        guard feeStroops > 0, feeStroops <= Int64(UInt32.max) else {
            throw StellarTransactionXDRBuilderError.invalidFee
        }
        let sourceKey = try accountIDBytes(source)
        let signingKey: Curve25519.Signing.PrivateKey
        do {
            signingKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: privateKeyData
            )
        } catch {
            throw StellarTransactionXDRBuilderError.invalidPrivateKey
        }
        guard signingKey.publicKey.rawRepresentation == sourceKey else {
            throw StellarTransactionXDRBuilderError.sourceAccountMismatch
        }

        var transaction = StellarXDRWriter()
        transaction.appendInt32(publicKeyTypeEd25519)
        transaction.appendFixedOpaque(sourceKey)
        transaction.appendUInt32(UInt32(feeStroops))
        transaction.appendInt64(sequence)
        transaction.appendInt32(0) // Preconditions: none.
        try appendMemo(memo, to: &transaction)
        transaction.appendUInt32(1) // Exactly one reviewed operation.
        transaction.appendInt32(0) // Operation source account: absent.
        try appendOperation(operation, to: &transaction)
        transaction.appendInt32(0) // Transaction extension: v0.

        let networkID = Data(
            SHA256.hash(
                data: Data(StellarConstants.networkPassphrase.utf8)
            )
        )
        var signatureBase = StellarXDRWriter()
        signatureBase.appendFixedOpaque(networkID)
        signatureBase.appendInt32(envelopeTypeTransaction)
        signatureBase.appendFixedOpaque(transaction.data)
        let transactionHash = Data(SHA256.hash(data: signatureBase.data))
        let signature: Data
        do {
            signature = try signingKey.signature(for: transactionHash)
        } catch {
            throw StellarTransactionXDRBuilderError.invalidPrivateKey
        }
        guard signature.count == 64 else {
            throw StellarTransactionXDRBuilderError.invalidPrivateKey
        }

        var envelope = StellarXDRWriter()
        envelope.appendInt32(envelopeTypeTransaction)
        envelope.appendFixedOpaque(transaction.data)
        envelope.appendUInt32(1) // One decorated signature.
        envelope.appendFixedOpaque(sourceKey.suffix(4))
        envelope.appendVariableOpaque(signature)
        return StellarSignedTransaction(
            envelopeXDR: envelope.data.base64EncodedString(),
            transactionHash: transactionHash.hexString.lowercased()
        )
    }

    static func accountIDBytes(_ address: String) throws -> Data {
        guard let address = StellarAddress.validated(address),
              let decoded = StellarBase32.decode(address),
              decoded.count == 35,
              decoded[decoded.startIndex] == 6 << 3
        else {
            throw StellarTransactionXDRBuilderError.invalidAddress
        }
        let payload = decoded.dropLast(2)
        let storedChecksum = UInt16(decoded[decoded.count - 2])
            | (UInt16(decoded[decoded.count - 1]) << 8)
        guard StellarCRC16.xmodem(payload) == storedChecksum else {
            throw StellarTransactionXDRBuilderError.invalidAddress
        }
        return Data(payload.dropFirst())
    }

    private static func appendMemo(
        _ memo: String?,
        to writer: inout StellarXDRWriter
    ) throws {
        guard let memo else {
            writer.appendInt32(0)
            return
        }
        guard let validated = StellarMemoTextValidator.validated(memo) else {
            throw StellarTransactionXDRBuilderError.invalidMemo
        }
        writer.appendInt32(1)
        writer.appendString(validated)
    }

    private static func appendOperation(
        _ operation: StellarTransactionOperation,
        to writer: inout StellarXDRWriter
    ) throws {
        switch operation {
        case let .createAccount(destination, amountStroops):
            guard amountStroops > 0 else {
                throw StellarTransactionXDRBuilderError.invalidAmount
            }
            writer.appendInt32(0)
            try appendAccountID(destination, to: &writer)
            writer.appendInt64(amountStroops)
        case let .payment(destination, asset, amountStroops):
            guard amountStroops > 0 else {
                throw StellarTransactionXDRBuilderError.invalidAmount
            }
            writer.appendInt32(1)
            try appendMuxedAccount(destination, to: &writer)
            try appendAsset(asset, to: &writer)
            writer.appendInt64(amountStroops)
        }
    }

    private static func appendMuxedAccount(
        _ address: String,
        to writer: inout StellarXDRWriter
    ) throws {
        writer.appendInt32(publicKeyTypeEd25519)
        writer.appendFixedOpaque(try accountIDBytes(address))
    }

    private static func appendAccountID(
        _ address: String,
        to writer: inout StellarXDRWriter
    ) throws {
        writer.appendInt32(publicKeyTypeEd25519)
        writer.appendFixedOpaque(try accountIDBytes(address))
    }

    private static func appendAsset(
        _ asset: StellarAssetIdentity?,
        to writer: inout StellarXDRWriter
    ) throws {
        guard let asset else {
            writer.appendInt32(0)
            return
        }
        let code = Data(asset.code.utf8)
        switch code.count {
        case 1...4:
            writer.appendInt32(1)
            writer.appendFixedOpaque(code, paddedTo: 4)
        case 5...12:
            writer.appendInt32(2)
            writer.appendFixedOpaque(code, paddedTo: 12)
        default:
            throw StellarTransactionXDRBuilderError.invalidAsset
        }
        try appendAccountID(asset.issuer, to: &writer)
    }
}

private struct StellarXDRWriter {
    private(set) var data = Data()

    mutating func appendInt32(_ value: Int32) {
        appendInteger(value.bigEndian)
    }

    mutating func appendUInt32(_ value: UInt32) {
        appendInteger(value.bigEndian)
    }

    mutating func appendInt64(_ value: Int64) {
        appendInteger(value.bigEndian)
    }

    mutating func appendFixedOpaque(_ value: some DataProtocol) {
        data.append(contentsOf: value)
    }

    mutating func appendFixedOpaque(
        _ value: Data,
        paddedTo length: Int
    ) {
        precondition(value.count <= length)
        data.append(value)
        data.append(Data(repeating: 0, count: length - value.count))
    }

    mutating func appendVariableOpaque(_ value: Data) {
        appendUInt32(UInt32(value.count))
        data.append(value)
        appendPadding(for: value.count)
    }

    mutating func appendString(_ value: String) {
        appendVariableOpaque(Data(value.utf8))
    }

    private mutating func appendInteger<T>(_ value: T) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }

    private mutating func appendPadding(for byteCount: Int) {
        let padding = (4 - (byteCount % 4)) % 4
        if padding > 0 {
            data.append(Data(repeating: 0, count: padding))
        }
    }
}

private enum StellarBase32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    private static let values = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) }
    )

    static func decode(_ value: String) -> Data? {
        var buffer = 0
        var bitCount = 0
        var output = Data()
        for character in value {
            guard let digit = values[character] else { return nil }
            buffer = (buffer << 5) | digit
            bitCount += 5
            while bitCount >= 8 {
                bitCount -= 8
                output.append(UInt8((buffer >> bitCount) & 0xFF))
                buffer &= (1 << bitCount) - 1
            }
        }
        guard bitCount == 0 || (buffer & ((1 << bitCount) - 1)) == 0 else {
            return nil
        }
        return output
    }
}

private enum StellarCRC16 {
    static func xmodem(_ value: some DataProtocol) -> UInt16 {
        var crc: UInt16 = 0
        for byte in value {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0
                    ? (crc << 1) ^ 0x1021
                    : crc << 1
            }
        }
        return crc
    }
}
