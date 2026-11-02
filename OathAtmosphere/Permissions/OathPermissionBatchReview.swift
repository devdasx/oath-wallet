import SwiftUI
import OathAnkr
import OathDatabase
import OathDiagnostics

/// Owns only preparation and authentication. The durable coordinator owns signed work.
@MainActor @Observable final class OathPermissionRevokeAction {
    private(set) var pending = Set<String>()
    private(set) var busy = false
    private(set) var verifiedAbsent = Set<String>()
    var passcode = false
    var notice: OathStringKey?
    var failure: OathStringKey?
    private var prepared = [PermissionBatchItem]()
    private var claim: UUID?
    private var task: Task<Void,Never>?
    private var selection: PermissionReviewSelection?
    private var coordinator: OathPermissionBatchCoordinator { .shared }

    func revoke(_ permissions: [WalletPermission], session: OathWalletSession, model: OathPermissionsModel, reason: String) {
        guard session.isUnlocked,
              session.wallets.contains(where:{$0.id == model.walletID && $0.kind != "watchOnly"}),
              let selection=PermissionReviewSelection(walletID:model.walletID,items:permissions),
              coordinator.claimPreparation(selection.id) else { return }
        self.selection=selection;claim=selection.id
        pending=Set(permissions.map(\.id));verifiedAbsent=[];failure=nil;notice=nil;busy=true
        task=Task { await prepare(session:session,model:model,selection:selection,reason:reason) }
    }

    func enterPasscode(_ input: [UInt8], session: OathWalletSession, model: OathPermissionsModel, reason: String) {
        guard !busy, let selection, claim == selection.id else { return }
        busy=true
        task=Task { await authorize(input,session:session,model:model,selection:selection,reason:reason) }
    }

    func cancel() {
        task?.cancel()
        finish()
    }
    func dismissPasscode() {
        // A completed authentication may already have started a newer action.
        guard awaitingPasscodeDismissal else { return }
        awaitingPasscodeDismissal = false
        cancel()
    }
    private var awaitingPasscodeDismissal = false
    func passcodePresentationChanged(_ presented: Bool) {
        if !presented, passcode { awaitingPasscodeDismissal = true }
        passcode = presented
    }
    private func finish(_ expected: UUID? = nil) {
        if let expected, claim != expected { return }
        if let claim { coordinator.releasePreparation(claim) }
        claim=nil;selection=nil;pending=[];prepared=[];busy=false;passcode=false;notice=nil;awaitingPasscodeDismissal=false
    }

    private func authorize(_ input: [UInt8]?, session: OathWalletSession, model: OathPermissionsModel,
                           selection: PermissionReviewSelection, reason: String) async {
        var digits=input
        defer { if digits != nil { _ = digits!.withUnsafeMutableBytes{$0.initializeMemory(as:UInt8.self,repeating:0)} } }
        guard !Task.isCancelled, claim == selection.id, model.walletID == selection.walletID,
              session.isUnlocked, !prepared.isEmpty else { finish(selection.id);return }
        busy=true;failure=nil
        do {
            let grant=try await session.vault.authorizePermissionBatch(prepared.compactMap(\.scope),digits:digits,reason:reason)
            guard !Task.isCancelled, claim == selection.id, model.walletID == selection.walletID, session.isUnlocked else {
                await session.vault.endPermissionBatch(grant)
                finish(selection.id);return
            }
            try await coordinator.start(prepared,authorization:grant,vault:session.vault,preparation:selection.id)
            finish(selection.id)
        } catch {
            guard claim == selection.id else { return }
            if error is OathBiometricCredentialError { passcode=true;busy=false }
            else if error as? OathWalletError == .wrongPasscode { passcode=true;notice = .unlockIncorrect;busy=false }
            else if case OathWalletError.throttled = error { passcode=true;notice = .unlockWait;busy=false }
            else {
                // User cancellation is not a revocation failure.
                if !(error is CancellationError) {
                    OathDiagnostics.record(error,component:"permissions",operation:"direct_authorize")
                    failure=OathPermissionReview.message(error)
                }
                finish(selection.id)
            }
        }
    }
    private func prepare(session: OathWalletSession, model: OathPermissionsModel, selection: PermissionReviewSelection, reason: String) async {
        let walletID=selection.walletID, items=selection.items
        let isCurrentWallet = model.walletID == walletID
        guard isCurrentWallet, session.isUnlocked else { cancel(); return }
        busy=true;failure=nil;prepared=[]
        let batchID=UUID().uuidString, createdAt=Date.now.timeIntervalSince1970
        do {
            let db=try await session.vault.database()
            let accounts=try await db.accounts(walletID:walletID)
            let candidates=items
            try await withThrowingTaskGroup(of:PermissionBatchItem.self) { group in
                var next=0
                func enqueue() {
                    guard next<candidates.count,!Task.isCancelled else { return }
                    let ordinal=next,permission=candidates[next];next += 1
                    group.addTask {
                        try Task.checkCancellation()
                        let account=accounts.first(where: { account in
                            guard account.networkID == permission.network else { return false }
                            return WalletPermission.identityKey(network:permission.network,address:account.address)
                                == WalletPermission.identityKey(network:permission.network,address:permission.owner)
                        })
                        let id=UUID().uuidString
                        var scope:PermissionBatchScope?,state="queued",code:String?
                        do {
                            guard let account else { throw PermissionError.changed }
                            scope=try await OathDiagnostics.$chain.withValue(permission.network) {
                                try await OathDiagnostics.$operationID.withValue(UUID()) {
                                    let quote=try await OathPermissionService.shared.quote(permission,account:account,database:db)
                                    return try quote.scope(sendID:id)
                                }
                            }
                        } catch {
                            if error is CancellationError || Task.isCancelled { throw CancellationError() }
                            state=error as? PermissionError == .alreadyRemoved ? "alreadyRemoved":"failed"
                            code=OathPermissionBatchCoordinator.failureCode(error)
                            if state != "alreadyRemoved", !(error is SendFeeFundingError), error as? EVMSendError != .insufficientFunds,
                               error as? TronSendError != .insufficientFunds,error as? SolanaSendError != .insufficientFunds {
                                OathDiagnostics.record(error,component:"permissions",operation:"batch_prepare",context:["chain":permission.network])
                            }
                        }
                        return .init(id:id,batchID:batchID,walletID:walletID,accountID:account?.id ?? "",
                            permission:permission,scope:scope,ordinal:ordinal,createdAt:createdAt,state:state,errorCode:code)
                    }
                }
                for _ in 0..<min(4,candidates.count) { enqueue() }
                for try await item in group {
                    guard !Task.isCancelled,session.isUnlocked,model.walletID == walletID,claim == selection.id else { group.cancelAll();throw CancellationError() }
                    prepared.append(item)
                    enqueue()
                }
                prepared.sort{$0.ordinal<$1.ordinal}
                // A fresh zero allowance is already revoked; persist the refreshed scan.
                for item in prepared where item.state == "alreadyRemoved" {
                    guard let scan=model.scans[item.permission.network] else { continue }
                    let updated=PermissionScan(network:scan.network,owner:scan.owner,
                        permissions:scan.permissions.filter{$0.id != item.permission.id},coverage:scan.coverage,checkedAt:scan.checkedAt)
                    try await db.savePermissionScan(walletID:walletID,accountID:item.accountID,scan:updated)
                    guard !Task.isCancelled, claim == selection.id, model.walletID == walletID, session.isUnlocked else { throw CancellationError() }
                    model.scans[scan.network]=updated
                    verifiedAbsent.insert(item.permission.id)
                }
                if let failed=prepared.first(where:{$0.state == "failed"}) {
                    failure=OathPermissionBatchReview.failureKey(failed)
                    finish(selection.id);return
                }
                prepared.removeAll{$0.state == "alreadyRemoved"}
                guard !prepared.isEmpty else { finish(selection.id);return }
                busy=false
                await authorize(nil,session:session,model:model,selection:selection,reason:reason)
            }
        } catch {
            if !(error is CancellationError) { OathDiagnostics.record(error,component:"permissions",operation:"direct_prepare");if claim == selection.id { failure = .permissionError } }
            finish(selection.id)
        }
    }
}

struct OathPermissionAuthentication: ViewModifier {
    @Bindable var action: OathPermissionRevokeAction
    let session: OathWalletSession
    let model: OathPermissionsModel
    @Environment(\.oathLocalizer) private var strings
    func body(content: Content) -> some View {
        content
            .sheet(isPresented:Binding(get:{action.passcode},set:{action.passcodePresentationChanged($0)}),onDismiss:{ action.dismissPasscode() }) {
                NavigationStack {
                    OathSecretPasscodePage(session:session,busy:action.busy,notice:$action.notice,
                        title:.permissionRemove,identifier:"permissions.passcode") {
                        action.enterPasscode($0,session:session,model:model,reason:strings.text(.permissionRemove))
                    }
                    .toolbar { ToolbarItem(placement:.cancellationAction) { OathCloseButton { action.cancel() }.disabled(action.busy) } }
                }
                .interactiveDismissDisabled(action.busy)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .oathNativeLocalization()
            }
            .onChange(of:model.walletID) { _,_ in action.cancel() }
            .onChange(of:session.isUnlocked) { _,unlocked in if !unlocked { action.cancel() } }
            .onDisappear { action.cancel() }
    }
}

enum OathPermissionBatchReview {
    static func symbol(_ network: String) -> String { EVMSendNetwork(rawValue:network)?.symbol ?? (network=="tron" ? "TRX":"SOL") }
    static func fee(_ scope: PermissionBatchScope) -> String {
        let decimals=scope.network=="tron" ? 6:scope.network=="solana" ? 9:18
        return OathAssetAmountFormat.boundedUnits(OathSendAmount.units(String(scope.maximumFee),decimals:decimals) ?? "—")+" "+symbol(scope.network)
    }
    static func failureKey(_ item: PermissionBatchItem) -> OathStringKey {
        if item.state=="queued" { return .wcMaximumFee }
        if item.state=="alreadyRemoved" { return .permissionAlready }
        switch item.errorCode { case "changed":return .permissionChanged;case "insufficient":return .permissionInsufficient
        case "unsupported":return .permissionUnsupported;default:return .permissionError }
    }
}
