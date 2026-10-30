import SwiftUI
import OathAnkr
import OathDatabase
import OathDiagnostics

struct OathPermissionBatchReview: View {
    let session: OathWalletSession, model: OathPermissionsModel
    let selection: PermissionReviewSelection
    private var items: [WalletPermission] { selection.items }
    private var walletID: String { selection.walletID }
    private var isCurrentWallet: Bool {
        model.walletID == walletID && session.wallets.contains { $0.id == walletID && $0.kind != "watchOnly" }
    }
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var prepared: [PermissionBatchItem] = []
    @State private var busy = false
    @State private var confirming = false
    @State private var passcode = false
    @State private var notice: OathStringKey?
    @State private var failure: OathStringKey?
    private var scopes: [PermissionBatchScope] { prepared.compactMap(\.scope) }
    private var coordinator: OathPermissionBatchCoordinator { .shared }
    private var canConfirm: Bool {
        !busy && isCurrentWallet && !scopes.isEmpty && prepared.count == items.count && prepared.allSatisfy { !$0.accountID.isEmpty } && session.isUnlocked && coordinator.runningWalletID == nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if passcode {
                    OathSecretPasscodePage(session:session,busy:busy,notice:$notice,
                        title:.permissionRevokeAll,identifier:"permissions.batch.passcode") { approve($0) }
                } else {
                    OathPermissionContent {
                        OathSettingsRow(title:strings.text(.walletName),
                            value:session.walletName(session.wallets.first{$0.id==walletID},strings:strings),accessory:.none)
                        ForEach(items) { permission in
                            let item = prepared.first { $0.permission.id == permission.id }
                            OathSettingsSectionRule()
                            OathPermissionRemovalSummary(model:model,permission:permission)
                            OathSettingsRow(title:strings.text(.wcMaximumFee),
                                value:item?.scope.map(Self.fee) ?? "—",accessory:.none,
                                isWorking:busy && item == nil)
                            if let item, item.state != "queued" {
                                OathSettingsFooter {
                                    Text(strings.text(Self.failureKey(item)))
                                        .foregroundStyle(item.state == "failed" ? Color.red : Color.secondary)
                                }
                            }
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
                        if failure != nil || prepared.contains(where: { $0.state == "failed" }) {
                            Button { Task { await prepare() } } label: {
                                OathSettingsRow(title:strings.text(.tryAgain),icon:"arrow.clockwise")
                            }.buttonStyle(OathSettingsRowButtonStyle()).disabled(busy || !isCurrentWallet)
                        }
                    }
                }
            }
            .navigationTitle(strings.text(.permissionReview)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { OathCloseButton { dismiss() }.disabled(busy) }
            }
            .oathBottomActions(isPresented: !passcode) {
                OathBottomAction(title: strings.text(items.count == 1 ? .permissionRemove : .permissionRevokeAll),
                                 identifier: "permissions.batch.revoke", role: .destructive,
                                 isEnabled: canConfirm, isWorking: busy) {
                    guard canConfirm, !passcode, scenePhase != .background else { return }
                    confirming = true
                }
            }
            .toolbar(.hidden, for: .bottomBar)
            .alert(strings.text(items.count == 1 ? .permissionRemove:.permissionRevokeAll),isPresented:$confirming) {
                Button(strings.text(.cancel),role:.cancel) {}
                Button(strings.text(items.count == 1 ? .permissionRemove:.permissionRevokeAll),role:.destructive) { approve(nil) }
            } message: {
                Text(confirmation)
            }
        }
        .task { await prepare() }
        .task(id:selection.id) { await model.resolveIdentities(session:session,items:items) }
        .onChange(of:model.walletID) { _,current in if current != walletID { dismiss() } }
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
            let value=OathAssetAmountFormat(locale: strings.language.locale).native(total / pow(Decimal(10),decimals), ticker: Self.symbol(network))
            return (OathImportChain(rawValue:network)?.name ?? network)+": "+value
        }.joined(separator:"\n")
        return strings.format(.historySelectedCount,strings.number(scopes.count))+"\n\n" +
            strings.text(.wcMaximumFee)+"\n"+fees+"\n\n"+strings.text(.permissionBatchDetail)
    }
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
    private func prepare() async {
        guard !busy, isCurrentWallet, session.isUnlocked else { return }
        busy=true;failure=nil;prepared=[];defer{busy=false}
        let walletID=walletID, batchID=UUID().uuidString, createdAt=Date.now.timeIntervalSince1970
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
                    guard !Task.isCancelled,session.isUnlocked,isCurrentWallet else { group.cancelAll();throw CancellationError() }
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
        guard canConfirm else { return }
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
