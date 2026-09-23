import SwiftUI
import Observation

// Only display data is simulated. The group/store/list/capsule/timer sources are production files.
struct WalletDatabase: Sendable {}
struct SendTransactionAuthorization: Sendable {}
struct SendAssetChoice: Sendable {
    let id = "fixture-asset"
    let name = "Fixture Coin"
    let networkName = "Ethereum"
    let symbol = "ETH"
    let logoSource = "fixture"
}
struct SendDraft: Sendable {
    let asset = SendAssetChoice()
    let recipient: String
    let amount: String?
}
struct SendTransactionReceipt: Sendable { let amount: String? }
struct SendTransactionSubmissionOutcome: Sendable {}
struct SendTransactionSubmissionService: Sendable {
    init(database: WalletDatabase) {}
    func submit(draft: SendDraft, authorization: SendTransactionAuthorization) async throws -> SendTransactionSubmissionOutcome {
        fatalError("The UI fixture must never submit a transaction")
    }
}

@MainActor @Observable final class SendOperation: Identifiable {
    enum CapsuleStatus: Equatable {
        case sending, sent, confirming, confirmed, warning, failed
        var titleKey: String {
            switch self {
            case .sending: "send.activity.sending"
            case .sent: "send.activity.sent"
            case .confirming: "send.activity.confirming"
            case .confirmed: "wallet.activity.status.confirmed"
            case .warning: "send.broadcast.warning.title"
            case .failed: "wallet.activity.status.failed"
            }
        }
        var showsProgress: Bool { self == .sending || self == .confirming }
        var isTerminal: Bool { self == .confirmed || self == .failed }
    }
    let id: UUID
    let draft: SendDraft
    let walletAddress: String
    var receipt: SendTransactionReceipt? { .init(amount: draft.amount) }
    var capsuleStatus: CapsuleStatus = .confirming
    var receiptVisualStatus: CapsuleStatus { capsuleStatus }
    var networkStatus: CapsuleStatus? { capsuleStatus }
    var capsulePresentationID = UUID()
    var isAcknowledged = false
    var isSubmitting: Bool { capsuleStatus == .sending }
    var canRetry: Bool { capsuleStatus == .failed }
    init(database: WalletDatabase, draft: SendDraft, walletAddress: String,
         nativeUnitUSDPrice: Decimal?, onTransactionBroadcast: @escaping (SendTransactionReceipt) -> Void = { _ in }) {
        let index = Int(draft.recipient.replacingOccurrences(of: "Recipient-", with: "")) ?? 0
        self.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
        self.draft = draft
        self.walletAddress = walletAddress
    }
    func start(submission: @escaping @Sendable () async throws -> SendTransactionSubmissionOutcome) {
        fatalError("The UI fixture must never start a transaction")
    }
    func stopMonitoring() {}
    func finish(_ status: CapsuleStatus) {
        capsuleStatus = status
        isAcknowledged = false
        capsulePresentationID = UUID()
    }
}
