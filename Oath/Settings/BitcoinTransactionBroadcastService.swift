import Foundation

struct BitcoinTransactionBroadcastPreview: Equatable, Sendable {
    let normalizedHex: String
    let transactionID: String
    let byteCount: Int
    let inputCount: Int
    let outputCount: Int
}

struct BitcoinTransactionBroadcastResult: Equatable, Sendable {
    let transactionID: String
    let wasAlreadyKnown: Bool
}

enum BitcoinTransactionBroadcastValidationError:
    Error,
    Equatable,
    Sendable {
    case empty
    case invalid
    case tooLarge
}

enum BitcoinTransactionBroadcastError: Error, Equatable, Sendable {
    case notAttempted(code: String)
    case rejected(code: String, message: String?)
    case outcomeUnknown(code: String)
}

struct BitcoinTransactionBroadcastService: Sendable {
    /// Bitcoin Core's standard transaction-weight ceiling is 400,000 weight
    /// units. A serialized transaction larger than 400,000 bytes can never be
    /// standard, so reject it before allocating parser state or using network
    /// bandwidth. The network remains authoritative for weight-based policy.
    static let maximumSerializedByteCount = 400_000

    private let broadcaster: any SendBitcoinFamilyTransactionBroadcasting

    init(
        broadcaster: any SendBitcoinFamilyTransactionBroadcasting =
            SendBitcoinFamilyHTTPAPIClient.shared
    ) {
        self.broadcaster = broadcaster
    }

    func preview(
        for input: String
    ) throws -> BitcoinTransactionBroadcastPreview {
        let normalizedHex = try Self.normalizedHex(input)
        guard normalizedHex.count / 2 <= Self.maximumSerializedByteCount else {
            throw BitcoinTransactionBroadcastValidationError.tooLarge
        }
        guard let transaction = BitcoinRawTransaction(hex: normalizedHex),
              !transaction.inputs.isEmpty,
              !transaction.outputs.isEmpty else {
            throw BitcoinTransactionBroadcastValidationError.invalid
        }

        return BitcoinTransactionBroadcastPreview(
            normalizedHex: normalizedHex,
            transactionID: transaction.transactionID,
            byteCount: normalizedHex.count / 2,
            inputCount: transaction.inputs.count,
            outputCount: transaction.outputs.count
        )
    }

    func broadcast(
        _ preview: BitcoinTransactionBroadcastPreview
    ) async throws -> BitcoinTransactionBroadcastResult {
        do {
            let result = try await broadcaster.broadcast(
                chain: .bitcoin,
                rawTransactionHex: preview.normalizedHex,
                expectedTransactionID: preview.transactionID
            )
            let normalizedID = result.transactionID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard Self.isTransactionID(normalizedID),
                  normalizedID == preview.transactionID.lowercased() else {
                throw BitcoinTransactionBroadcastError.outcomeUnknown(
                    code: "transaction_id_mismatch"
                )
            }
            return BitcoinTransactionBroadcastResult(
                transactionID: normalizedID,
                wasAlreadyKnown: result.wasAlreadyKnown
            )
        } catch let error as SendBitcoinFamilyHTTPBroadcastError {
            switch error {
            case let .notAttempted(provider, code):
                throw BitcoinTransactionBroadcastError.notAttempted(
                    code: "\(provider)_\(code)"
                )
            case let .rejected(provider, code, message):
                throw BitcoinTransactionBroadcastError.rejected(
                    code: "\(provider)_\(code)",
                    message: message
                )
            case let .outcomeUnknown(provider, code):
                throw BitcoinTransactionBroadcastError.outcomeUnknown(
                    code: "\(provider)_\(code)"
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BitcoinTransactionBroadcastError {
            throw error
        } catch {
            throw BitcoinTransactionBroadcastError.outcomeUnknown(
                code: Self.sanitizedErrorType(error)
            )
        }

    }

    static func normalizedHex(_ input: String) throws -> String {
        var compact = String(input.filter { !$0.isWhitespace })
        if compact.lowercased().hasPrefix("0x") {
            compact.removeFirst(2)
        }
        guard !compact.isEmpty else {
            throw BitcoinTransactionBroadcastValidationError.empty
        }
        guard compact.count.isMultiple(of: 2),
              compact.utf8.allSatisfy(Self.isASCIIHexByte) else {
            throw BitcoinTransactionBroadcastValidationError.invalid
        }
        guard compact.count / 2 <= maximumSerializedByteCount else {
            throw BitcoinTransactionBroadcastValidationError.tooLarge
        }
        return compact.lowercased()
    }

    private static func isASCIIHexByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...70, 97...102:
            true
        default:
            false
        }
    }

    private static func isTransactionID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy(isASCIIHexByte)
    }

    private static func sanitizedErrorType(_ error: Error) -> String {
        let normalized = String(reflecting: type(of: error)).lowercased().map {
            character in
            character.isASCII && (character.isLetter || character.isNumber)
                ? character : "_"
        }
        let compact = String(normalized)
            .split(separator: "_")
            .prefix(8)
            .joined(separator: "_")
        return compact.isEmpty ? "unknown" : String(compact.prefix(96))
    }
}
