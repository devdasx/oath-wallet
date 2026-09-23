import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class SendRecipientHistoryModel {
    private(set) var snapshot: SendRecipientHistorySnapshot?
    private(set) var errorMessage: String?
    private var scope: SendRecipientHistoryScope?
    private var observationID: UUID?

    var recentRecipients: [SendRecentRecipient] { snapshot?.recentRecipients ?? [] }

    func assessment(address: String?, networkID: String, memo: String? = nil) -> SendRecipientHistoryAssessment? {
        guard errorMessage == nil, let address else { return nil }
        return snapshot?.assessment(address: address, networkID: networkID, memo: memo)
    }

    func observe(database: WalletDatabase, asset: SendAssetChoice) async {
        let id = UUID()
        observationID = id
        errorMessage = nil
        do {
            let scope: SendRecipientHistoryScope
            if let capturedScope = self.scope { scope = capturedScope }
            else { scope = try await database.sendRecipientHistoryScope(asset: asset) }
            guard !Task.isCancelled, observationID == id else { return }
            self.scope = scope
            for try await snapshot in database.sendRecipientHistoryObservation(scope: scope) {
                guard !Task.isCancelled, observationID == id else { return }
                self.snapshot = snapshot
            }
        } catch {
            guard !Task.isCancelled, observationID == id else { return }
            snapshot = nil
            if let error = error as? SendRecipientHistoryError {
                errorMessage = error.localizedMessage
            } else {
                // A SQLite code is actionable; SQL and bound wallet values are not safe UI copy.
                let code = (error as? DatabaseError).map { "sqlite_\($0.extendedResultCode.rawValue)" }
                    ?? "history_read"
                errorMessage = EnglishNumbers.localized("send.recipient.history.read_failed", code)
            }
        }
    }
}
