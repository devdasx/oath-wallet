import Foundation
import Observation
import UIKit
import OathAnkr
import OathDatabase
import OathDiagnostics

/// App-lifetime owner. Dismissing a screen does not cancel approved work.
/// A lock, expired grant or OS execution limit pauses unsigned items. Signed
/// transactions remain owned by the existing durable send-status worker.
@MainActor @Observable final class OathPermissionBatchCoordinator {
    static let shared = OathPermissionBatchCoordinator()
    private(set) var runningWalletID: String?
    private var job: Task<Void,Never>?
    private var assertion: UIBackgroundTaskIdentifier = .invalid

    func start(_ items: [PermissionBatchItem], authorization: UUID, vault: OathWalletVault) async throws {
        guard job == nil, runningWalletID == nil, let walletID=items.first?.walletID else {
            await vault.endPermissionBatch(authorization)
            throw PermissionError.changed
        }
        runningWalletID=walletID
        do {
            let db=try await vault.database()
            try await db.savePermissionBatch(items)
        } catch {
            runningWalletID=nil
            await vault.endPermissionBatch(authorization)
            OathDiagnostics.record(error,component:"permissions",operation:"batch_save")
            throw error
        }
        assertion=UIApplication.shared.beginBackgroundTask(withName:"Revoke permissions") { [weak self] in
            // UIKit invokes expiration on MainActor. Release its allowance
            // before returning; cancelled network/storage work may still be
            // suspended. Keep job ownership until that work actually finishes.
            self?.job?.cancel()
            self?.endBackgroundAssertion()
        }
        job=Task { await run(items,authorization:authorization,vault:vault) }
    }

    private func run(_ items: [PermissionBatchItem], authorization: UUID, vault: OathWalletVault) async {
        defer {
            job=nil; runningWalletID=nil
            endBackgroundAssertion()
        }
        do {
            let db=try await vault.database()
            let indexed=Dictionary(uniqueKeysWithValues:items.map { ($0.id,$0) })
            try await PermissionBatchExecutor.run(ids:items.filter{$0.state=="queued"}.map(\.id), authorized: {
                await vault.permissionBatchIsAuthorized(authorization)
            }, execute: { id in
                guard let item=indexed[id], let reviewed=item.scope else { throw PermissionError.changed }
                try await OathDiagnostics.$chain.withValue(item.permission.network) {
                    try await OathDiagnostics.$operationID.withValue(UUID()) {
                        do {
                            // Never create new bytes for a previously journaled item.
                            if let send=try await db.send(id), send.signedPayload != nil { return }
                            guard try await db.permissionBatchCanPrepare(reviewed) else { throw EVMSendError.busy }
                            guard let account=try await db.account(item.accountID),account.walletID==item.walletID else { throw PermissionError.changed }
                            let quote=try await OathPermissionService.shared.quote(item.permission,account:account,database:db)
                            guard reviewed.permits(try quote.scope(sendID:id)) else { throw PermissionError.changed }
                            try await db.setPermissionBatchItem(id,state:"processing")
                            _ = try await OathPermissionService.shared.submit(quote,vault:vault,digits:nil,
                                reason:"",permissionSendID:id,authorization:authorization)
                        } catch {
                            if !(error is CancellationError), error as? PermissionError != .alreadyRemoved,
                               error as? EVMSendError != .busy, error as? TronSendError != .busy,
                               error as? SolanaSendError != .busy {
                                OathDiagnostics.record(error,component:"permissions",operation:"batch_revoke",context:["chain":item.permission.network])
                            }
                            throw error
                        }
                    }
                }
            }, finish: { id,outcome,error in
                let state: String
                switch outcome { case .submitted:state="submitted";case .failed:state="failed";case .paused:state="paused";case .alreadyRemoved:state="alreadyRemoved" }
                try await db.setPermissionBatchItem(id,state:state,errorCode:error.map(Self.failureCode))
            })
            if let walletID=items.first?.walletID { try await db.reconcilePermissionBatches(walletID:walletID,interruptUnsigned:true) }
        } catch {
            if !(error is CancellationError) { OathDiagnostics.record(error,component:"permissions",operation:"batch_run") }
            // Storage/reset interruptions leave the journal authoritative. The
            // next visit reconciles it before offering any retry.
        }
        await vault.endPermissionBatch(authorization)
    }

    private func endBackgroundAssertion() {
        guard assertion != .invalid else { return }
        let ended = assertion
        assertion = .invalid
        UIApplication.shared.endBackgroundTask(ended)
    }
    nonisolated static func failureCode(_ error: any Error) -> String {
        if error as? PermissionError == .changed || error as? EVMSendError == .changed || error as? SolanaSendError == .changed { return "changed" }
        if error is SendFeeFundingError || error as? EVMSendError == .insufficientFunds || error as? TronSendError == .insufficientFunds || error as? SolanaSendError == .insufficientFunds { return "insufficient" }
        if error as? PermissionError == .unsupported { return "unsupported" }
        return "unavailable"
    }
}
