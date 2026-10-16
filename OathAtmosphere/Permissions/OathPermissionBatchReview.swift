import SwiftUI
import OathAnkr
import OathDatabase
import OathDiagnostics

struct OathPermissionBatchReview: View {
    let session: OathWalletSession, model: OathPermissionsModel
    let items: [WalletPermission]
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dismiss) private var dismiss
    @State private var prepared: [PermissionBatchItem] = []
    @State private var busy = false
    @State private var confirming = false
    @State private var passcode = false
    @State private var notice: OathStringKey?
    @State private var failure: OathStringKey?
    private var scopes: [PermissionBatchScope] { prepared.compactMap(\.scope) }
    private var coordinator: OathPermissionBatchCoordinator { .shared }

    var body: some View {
        NavigationStack {
            Group {
                if passcode {
                    OathSecretPasscodePage(session:session,busy:busy,notice:$notice,
                        title:.permissionRevokeAll,identifier:"permissions.batch.passcode") { approve($0) }
                } else {
                    OathPermissionContent {
                        OathSettingsRow(title:strings.text(.walletName),
                            value:session.walletName(session.wallets.first{$0.id==model.walletID},strings:strings),accessory:.none)
                        OathSettingsFooter { Text(strings.text(.permissionBatchDetail)) }
                        ForEach(items) { permission in
                            let item=prepared.first{$0.permission.id==permission.id}
                            OathSettingsRow(title:model.name(permission) ?? WalletPermission.abbreviated(permission.identityAddress),
                                value:item.flatMap(\.scope).map(Self.fee), accessory:.none,
                                subtitle:(model.spenderName(permission) ?? WalletPermission.abbreviated(permission.spender))+"\n"+(item.map { strings.text(Self.failureKey($0)) } ?? strings.text(.sendLoadingFee)),
                                networkLogo:"network-"+permission.network,isWorking:busy && prepared.isEmpty)
                        }
                        OathSettingsSectionRule()
                        OathSettingsFooter { Text(strings.text(.permissionNoTransfer)) }
                        if items.contains(where:{$0.kind == .accountControl}) {
                            OathSettingsFooter { Text(strings.text(.permissionControlDetail)) }
                        }
                        if items.contains(where:{$0.kind == .delegation}) {
                            OathSettingsFooter { Text(strings.text(.permissionDelegationDetail)) }
                        }
                        if let failure { OathSettingsFooter { Text(strings.text(failure)).foregroundStyle(.red) } }
                    }
                }
            }
            .navigationTitle(strings.text(.permissionReview)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { OathCloseButton { dismiss() }.disabled(busy) } }
            .oathBottomActions(isPresented:!passcode) {
                OathActionButton(title:strings.text(items.count == 1 ? .permissionRemove:.permissionRevokeAll),
                                 icon:"hand.raised.slash",role:.destructive,accent:.red,isWorking:busy) { confirming=true }
                    .disabled(busy || scopes.isEmpty || prepared.count != items.count || !session.isUnlocked || coordinator.runningWalletID != nil)
            }
            .alert(strings.text(items.count == 1 ? .permissionRemove:.permissionRevokeAll),isPresented:$confirming) {
                Button(strings.text(.cancel),role:.cancel) {}
                Button(strings.text(items.count == 1 ? .permissionRemove:.permissionRevokeAll),role:.destructive) { approve(nil) }
            } message: {
                Text(confirmation)
            }
        }
        .task { await prepare() }
        .onChange(of:session.isUnlocked) { _,unlocked in if !unlocked { dismiss() } }
        .interactiveDismissDisabled(busy)
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor:OathSurfaceColors.canvas)).oathNativeLocalization()
    }
    private var confirmation: String {
        let groups=Dictionary(grouping:scopes,by:\.network)
        let fees=groups.keys.sorted().map { network in
            let total=groups[network]!.reduce(Decimal.zero) { $0 + Decimal($1.maximumFee) }
            let decimals=network=="tron" ? 6:network=="solana" ? 9:18
            let value=(total / pow(Decimal(10),decimals)).formatted(.number.precision(.fractionLength(0...decimals)).locale(strings.language.locale))
            return (OathImportChain(rawValue:network)?.name ?? network)+": "+value+" "+Self.symbol(network)
        }.joined(separator:"\n")
        return strings.format(.historySelectedCount,strings.number(scopes.count))+"\n\n" +
            strings.text(.wcMaximumFee)+"\n"+fees+"\n\n"+strings.text(.permissionBatchDetail)
    }
    static func symbol(_ network: String) -> String { EVMSendNetwork(rawValue:network)?.symbol ?? (network=="tron" ? "TRX":"SOL") }
    static func fee(_ scope: PermissionBatchScope) -> String {
        let decimals=scope.network=="tron" ? 6:scope.network=="solana" ? 9:18
        return (OathSendAmount.units(String(scope.maximumFee),decimals:decimals) ?? "—")+" "+symbol(scope.network)
    }
    static func failureKey(_ item: PermissionBatchItem) -> OathStringKey {
        if item.state=="queued" { return .wcMaximumFee }
        if item.state=="alreadyRemoved" { return .permissionAlready }
        switch item.errorCode { case "changed":return .permissionChanged;case "insufficient":return .permissionInsufficient
        case "unsupported":return .permissionUnsupported;default:return .permissionError }
    }
    private func prepare() async {
        guard !busy, prepared.isEmpty, !items.isEmpty, items.count<=PermissionBatchScope.maximumItems, session.isUnlocked else { failure = .permissionError;return }
        busy=true;defer{busy=false}
        let walletID=model.walletID, batchID=UUID().uuidString, createdAt=Date.now.timeIntervalSince1970
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
                        guard let account=accounts.first(where:{$0.networkID==permission.network}) else { throw PermissionError.changed }
                        let id=UUID().uuidString
                        var scope:PermissionBatchScope?,state="queued",code:String?
                        do {
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
                            if state != "alreadyRemoved",error as? EVMSendError != .insufficientFunds,
                               error as? TronSendError != .insufficientFunds,error as? SolanaSendError != .insufficientFunds {
                                OathDiagnostics.record(error,component:"permissions",operation:"batch_prepare",context:["chain":permission.network])
                            }
                        }
                        return .init(id:id,batchID:batchID,walletID:walletID,accountID:account.id,
                            permission:permission,scope:scope,ordinal:ordinal,createdAt:createdAt,state:state,errorCode:code)
                    }
                }
                for _ in 0..<min(4,candidates.count) { enqueue() }
                for try await item in group {
                    guard !Task.isCancelled,session.isUnlocked else { group.cancelAll();throw CancellationError() }
                    prepared.append(item)
                    enqueue()
                }
                prepared.sort{$0.ordinal<$1.ordinal}
            }
        } catch {
            if !(error is CancellationError) { OathDiagnostics.record(error,component:"permissions",operation:"batch_review");failure = .permissionError }
        }
    }
    private func approve(_ input: [UInt8]?) {
        guard !busy,!scopes.isEmpty,prepared.count==items.count,session.isUnlocked,coordinator.runningWalletID==nil else { return }
        busy=true;failure=nil
        Task {
            var digits=input
            defer { if digits != nil { _ = digits!.withUnsafeMutableBytes{$0.initializeMemory(as:UInt8.self,repeating:0)} };busy=false }
            do {
                let grant=try await session.vault.authorizePermissionBatch(scopes,digits:digits,reason:strings.text(.permissionRevokeAll))
                try await coordinator.start(prepared,authorization:grant,vault:session.vault)
                dismiss()
            } catch {
                if error is OathBiometricCredentialError { passcode=true }
                else if error as? OathWalletError == .wrongPasscode { passcode=true;notice = .unlockIncorrect }
                else if case OathWalletError.throttled = error { passcode=true;notice = .unlockWait }
                else if !(error is CancellationError) {
                    OathDiagnostics.record(error,component:"permissions",operation:"batch_authorize")
                    failure = OathPermissionReview.message(error);passcode=false
                }
            }
        }
    }
}
