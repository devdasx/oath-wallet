import Foundation

struct BitcoinSilentPaymentScanHistory: Hashable, Sendable {
    let transactionHash: String
    let height: Int
    let tweakPublicKey: Data
}

struct BitcoinSilentPaymentScanResult: Sendable {
    let subscriptionAddress: String
    let startHeight: Int
    let scannedThroughHeight: Int
    let tipHeight: Int
    let history: [BitcoinSilentPaymentScanHistory]
    let rawTransactions: [String: String]
}

typealias BitcoinSilentPaymentScanProgressHandler = @Sendable (
    _ completionFraction: Decimal
) -> Void

final class BitcoinSilentPaymentLiveSubscription: @unchecked Sendable {
    let updates: AsyncThrowingStream<Void, Error>
    private let cancelAction: @Sendable () -> Void

    init(
        updates: AsyncThrowingStream<Void, Error>,
        cancelAction: @escaping @Sendable () -> Void
    ) {
        self.updates = updates
        self.cancelAction = cancelAction
    }

    func cancel() {
        cancelAction()
    }

    deinit {
        cancelAction()
    }
}

struct BitcoinSilentPaymentFrigateResponse: Decodable, Sendable {
    let id: BitcoinFamilyLosslessInt64?
    let result: JSONValue?
    let error: ElectrumRPCError?
    let method: String?
    let params: JSONValue?
}

enum BitcoinSilentPaymentScanError: Error, Equatable {
    case localScanningUnavailable
    case invalidKeyMaterial
    case unsupportedServer
    case wrongNetwork
    case invalidResponse
    case timedOut
}

/// Scanning is unavailable until a reviewed on-device implementation exists.
/// This type deliberately has no networking or key-serialization implementation.
actor BitcoinSilentPaymentScanClient {
    static let shared = BitcoinSilentPaymentScanClient()
    nonisolated static let isAvailable = false

    func scan(
        keyMaterial _: BitcoinSilentPaymentKeyMaterial,
        startHeight _: Int,
        endHeight _: Int? = nil,
        onProgress _: BitcoinSilentPaymentScanProgressHandler? = nil
    ) async throws -> BitcoinSilentPaymentScanResult {
        throw BitcoinSilentPaymentScanError.localScanningUnavailable
    }

    func tipHeight() async throws -> Int {
        throw BitcoinSilentPaymentScanError.localScanningUnavailable
    }

    func liveUpdates(
        keyMaterial _: BitcoinSilentPaymentKeyMaterial,
        startHeight _: Int
    ) async throws -> BitcoinSilentPaymentLiveSubscription {
        throw BitcoinSilentPaymentScanError.localScanningUnavailable
    }
}
