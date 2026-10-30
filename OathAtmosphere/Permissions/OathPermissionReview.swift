import SwiftUI
import OathAnkr
import OathDatabase
import OathDiagnostics

struct OathPermissionReview:View {
    let session:OathWalletSession,model:OathPermissionsModel,permission:WalletPermission
    @Environment(\.oathLocalizer) private var strings
    @State private var quote:OathPermissionService.Quote?
    @State private var busy=false
    @State private var passcode=false
    @State private var error:OathStringKey?
    @State private var notice:OathStringKey?
    @State private var submission:OathBitcoinSubmission?
    @State private var state:PermissionRemovalHistory?
    @State private var celebrated=false
    private var removed:Bool { state?.send.state=="confirmed" && state?.removal.status=="removed" }
    var body:some View {
        Group {
            if passcode {
                OathSecretPasscodePage(session:session,busy:busy,notice:$notice,title:.permissionRemove,identifier:"permissions.passcode") { submit($0) }
            } else if let submission {
                OathPermissionContent {
                    VStack(spacing:22) {
                        Image(systemName:removed ? "checkmark.circle.fill":"clock.arrow.circlepath")
                            .font(.system(size:64)).foregroundStyle(OathOnboardingColors.blue)
                            .symbolEffect(.bounce,value:removed)
                        Text(strings.text(statusTitle)).oathFont(.title2,weight:.semibold)
                        Text(strings.text(removed ? (permission.kind == .permit2Nonce ? .permissionNonceAdvanced:.permissionVerified):state?.send.state=="failed" ? .permissionFailed:state?.removal.status=="active" ? .permissionStillActive:.permissionPendingDetail)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(28)
                    OathSettingsSectionRule()
                    OathButton(feedback: nil) { OathClipboard.copy(submission.txid) } label:{OathAddressText(address:submission.txid,centered:false).padding(20)}.buttonStyle(.plain)
                    NavigationLink { OathPermissionHistoryPage(session:session,model:model) } label:{OathSettingsRow(title:strings.text(.permissionHistory),icon:"clock.arrow.circlepath")}.buttonStyle(OathSettingsRowButtonStyle())
                }
            } else {
                OathPermissionContent {
                    OathPermissionRemovalSummary(model:model,permission:permission)
                    OathSettingsRow(title:strings.text(.walletName),value:session.walletName(session.wallets.first{$0.id==model.walletID},strings:strings),accessory:.none)
                    OathSettingsSectionRule()
                    OathSettingsRow(title:strings.text(.transactionNetworkFee),value:fee,accessory:.none,isWorking:busy && quote==nil)
                    OathSettingsFooter { Text(strings.text(permission.kind == .permit2Nonce ? .permissionNonceDetail:permission.kind == .delegation ? .permissionDelegationDetail:permission.kind == .accountControl ? .permissionControlDetail:.permissionNoTransfer)) }
                    if let error {
                        OathSettingsFooter { Text(strings.text(error)) }
                        if error != .permissionChanged && error != .permissionAlready { Button { Task { await prepare() } } label:{OathSettingsRow(title:strings.text(.permissionScan),icon:"arrow.clockwise")}.buttonStyle(OathSettingsRowButtonStyle()).disabled(busy) }
                    }
                }
            }
        }
        .background(Color(uiColor:OathSurfaceColors.canvas).ignoresSafeArea())
        .navigationTitle(strings.text(submission==nil ? .permissionReview:statusTitle)).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if submission==nil,!passcode {
                ToolbarItem(placement:.topBarTrailing) {
                    if busy { ProgressView().tint(.secondary) }
                    else { OathDoneButton(label: .permissionRemove, role: .destructive) { submit(nil) }.disabled(quote==nil || !session.isUnlocked) }
                }
            }
        }
        .task { if quote==nil,submission==nil { await prepare() } }
        .task(id:permission.id) { await model.resolveIdentities(session:session,items:[permission]) }
        .task(id:submission?.txid) {
            guard let submission else { return }
            do {
                let db=try await session.vault.database()
                for try await entries in db.observePermissionHistory(walletID:model.walletID) {
                    guard !Task.isCancelled else { return }
                    state=entries.first{$0.send.transactionID==permission.network+":"+submission.txid}
                    if removed,!celebrated {
                        celebrated=true;OathHaptics.shared.play(.success)
                        if permission.kind != .permit2Nonce,let scan=model.scans[permission.network] {
                            model.scans[permission.network] = .init(network:scan.network,owner:scan.owner,permissions:scan.permissions.filter{$0.id != permission.id},coverage:scan.coverage,checkedAt:scan.checkedAt)
                        }
                    }
                }
            } catch { if !Task.isCancelled { OathDiagnostics.record(error,component:"permissions",operation:"observe_removal",context:["chain":permission.network]) } }
        }
        .onChange(of:session.isUnlocked) { _,unlocked in if !unlocked { quote=nil;passcode=false } }
        .oathNativeLocalization()
    }
    private var statusTitle:OathStringKey {
        if removed { return permission.kind == .permit2Nonce ? .permissionNonceAdvanced:.permissionRemoved }
        if state?.send.failureCode=="cancelled" {return .assetCanceled}
        if state?.send.failureCode=="replaced" {return .assetReplaced}
        if state?.send.failureCode=="expired" {return .permissionExpired}
        if state?.send.state=="failed" { return .permissionFailed }
        if state?.removal.status=="active" { return .permissionStillActive }
        return .permissionSubmitted
    }
    private var fee:String {
        guard let q=quote else { return "—" }
        guard let price=model.holdings.first(where:{$0.networkID==q.network && $0.reference=="native"})?.price.flatMap({Decimal(string:$0,locale:Locale(identifier:"en_US_POSIX"))}),
              let units=Decimal(string:OathSendAmount.units(String(q.fee),decimals:q.decimals) ?? "0",locale:Locale(identifier:"en_US_POSIX")) else { return OathAssetAmountFormat.boundedUnits(OathSendAmount.units(String(q.fee),decimals:q.decimals) ?? "—")+" "+(EVMSendNetwork(rawValue:q.network)?.symbol ?? (q.network=="tron" ? "TRX":"SOL")) }
        return OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.currency).money(units * price)
    }
    private func prepare() async {
        guard session.wallets.first(where:{$0.id==model.walletID})?.kind != "watchOnly" else { error = .permissionReadOnly;return }
        guard !busy,session.isUnlocked,let account=model.account(permission) else { return }
        busy=true;error=nil;quote=nil
        do {
            let result=try await PermissionPreparation.run(chain:permission.network) {
                try await OathPermissionService.shared.quote(permission,account:account,database:session.vault.database())
            }
            if !Task.isCancelled,session.isUnlocked { quote=result }
        } catch {
            // diagnostics: permission-preparation-feedback — the enclosing
            // PermissionPreparation boundary reports failures before rethrowing.
            if !Task.isCancelled { self.error=Self.message(error) }
        };busy=false
    }
    private func submit(_ digits:[UInt8]?) {
        guard !busy,session.isUnlocked,let quote else { return };busy=true;error=nil
        Task {
            var digits=digits
            defer { if digits != nil { _ = digits!.withUnsafeMutableBytes{$0.initializeMemory(as:UInt8.self,repeating:0)} };busy=false }
            do { submission=try await OathPermissionService.shared.submit(quote,vault:session.vault,digits:digits,reason:strings.text(.permissionRemove));passcode=false }
            catch {
                if error is OathBiometricCredentialError { passcode=true }
                else if error as? OathWalletError == .wrongPasscode { passcode=true;notice = .unlockIncorrect }
                else if case OathWalletError.throttled = error { passcode=true;notice = .unlockWait }
                else if !(error is CancellationError) { self.error=Self.message(error);self.quote=nil;passcode=false;OathDiagnostics.record(error,component:"permissions",operation:"submit",context:["chain":permission.network]) }
            }
        }
    }
    static func message(_ error:Error)->OathStringKey {
        if error as? PermissionError == .alreadyRemoved { return .permissionAlready }
        if error as? PermissionError == .changed || error as? EVMSendError == .changed || error as? SolanaSendError == .changed { return .permissionChanged }
        if error is SendFeeFundingError || error as? EVMSendError == .insufficientFunds || error as? TronSendError == .insufficientFunds || error as? SolanaSendError == .insufficientFunds { return .permissionInsufficient }
        if error as? PermissionError == .unsupported { return .permissionUnsupported }
        return .permissionError
    }
}

struct OathPermissionHistoryPage:View {
    let session:OathWalletSession,model:OathPermissionsModel
    @Environment(\.oathLocalizer) private var strings
    var body:some View {
        Group {
            if model.history.isEmpty { OathEmptyStateScrollView { OathEmptyState(strings.text(.permissionHistoryEmpty),systemImage:"clock.arrow.circlepath",description:strings.text(.permissionHistoryDetail)) } }
            else { OathPermissionContent {
                ForEach(model.history) { row in
                    let title:OathStringKey = row.removal.status=="removed" ? (isNonce(row) ? .permissionNonceAdvanced:.permissionRemoved):row.removal.status=="active" ? .permissionStillActive:row.send.failureCode=="cancelled" ? .assetCanceled:row.send.failureCode=="replaced" ? .assetReplaced:row.send.failureCode=="expired" ? .permissionExpired:row.send.state=="failed" ? .permissionFailed:.permissionPending
                    NavigationLink {
                        OathPermissionContent {
                            OathSettingsRow(title:strings.text(title),icon:row.removal.status=="removed" ? "checkmark.circle":"clock",accessory:.none)
                            OathSettingsRow(title:strings.text(.tokenNetwork),value:OathImportChain(rawValue:row.send.networkID)?.name ?? row.send.networkID,accessory:.none)
                            OathSettingsRow(title:strings.text(.permissionContract),value:WalletPermission.abbreviated(targets(row).0),accessory:.none)
                            OathButton(feedback: nil) { OathClipboard.copy(targets(row).0) } label:{OathAddressText(address:targets(row).0,centered:false).padding(20)}.buttonStyle(.plain)
                            OathSettingsRow(title:strings.text(.permissionSpender),accessory:.none)
                            OathButton(feedback: nil) { OathClipboard.copy(targets(row).1) } label:{OathAddressText(address:targets(row).1,centered:false).padding(20)}.buttonStyle(.plain)
                            OathSettingsRow(title:strings.text(.transactionNetworkFee),value:fee(row),accessory:.none)
                            Text(Date(timeIntervalSince1970:row.send.createdAt).formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(strings.language.locale))).foregroundStyle(.secondary).padding(20)
                            if let id=row.send.transactionID {
                                if let url=OathImportChain(rawValue:row.send.networkID)?.transactionExplorerURL(hash:String(id.dropFirst(row.send.networkID.count+1))) {Link(destination:url){OathSettingsRow(title:strings.text(.transactionViewExplorer),icon:"arrow.up.forward.square")}.buttonStyle(OathSettingsRowButtonStyle())}
                                OathButton(feedback: nil) { OathClipboard.copy(String(id.dropFirst(row.send.networkID.count+1))) } label:{OathAddressText(address:String(id.dropFirst(row.send.networkID.count+1)),centered:false).padding(20)}.buttonStyle(.plain)
                            }
                        }.navigationTitle(strings.text(.permissionHistory))
                    } label:{OathSettingsRow(title:strings.text(title),subtitle:Date(timeIntervalSince1970:row.send.createdAt).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(strings.language.locale)),networkLogo:"network-"+row.send.networkID)}.buttonStyle(OathSettingsRowButtonStyle())
                }
            } }
        }.navigationTitle(strings.text(.permissionHistory)).navigationBarTitleDisplayMode(.inline)
        .task {
            do { let db=try await session.vault.database();for try await entries in db.observePermissionHistory(walletID:model.walletID) { if Task.isCancelled { return };model.history=entries } }
            catch { if !Task.isCancelled { OathDiagnostics.record(error,component:"permissions",operation:"observe_history") } }
        }
    }
    private func isNonce(_ row:PermissionRemovalHistory)->Bool {if case .evm(let r)=row.operation {return r.kind == .permit2Nonce};return false}
    private func targets(_ row:PermissionRemovalHistory)->(String,String) {
        switch row.operation {case .evm(let r):(r.contract,r.spender);case .tron(let r):(r.contract,r.spender);case .solana(let r):(r.account,r.delegate)}
    }
    private func fee(_ row:PermissionRemovalHistory)->String {
        guard let amount=row.transaction?.feeAtomic else {return "—"}
        let decimals=row.send.networkID=="tron" ? 6:row.send.networkID=="solana" ? 9:18
        return OathAssetAmountFormat.boundedUnits(OathSendAmount.units(amount,decimals:decimals) ?? "—")+" "+(EVMSendNetwork(rawValue:row.send.networkID)?.symbol ?? (row.send.networkID=="tron" ? "TRX":"SOL"))
    }

}

/// The selected permission is visible before metadata/fees arrive, and remains
/// visible on failure. Identity metadata is display-only and never changes scope.
struct OathPermissionRemovalSummary: View {
    let model: OathPermissionsModel
    let permission: WalletPermission
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dismiss) private var dismiss
    private var identity: ContractIdentity? { model.identity(permission) }
    private var holding: Holding? { model.holding(permission) }
    private var symbol: String? { identity?.symbol ?? holding?.symbol }
    private var decimals: Int? { identity?.decimals ?? holding?.decimals }
    private var isControl: Bool { [.accountControl,.delegation].contains(permission.kind) }
    private var access: String {
        if permission.hasUnlimitedTokenAllowance { return strings.text(.permissionUnlimited) }
        if let amount = permission.tokenAllowance {
            if let decimals, let units = OathSendAmount.units(amount,decimals:decimals) {
                return OathAssetAmountFormat.boundedUnits(units) + (symbol.map { " " + $0 } ?? "")
            }
            return amount + " · " + strings.text(.permissionAtomic)
        }
        return strings.text(permission.kindTitle)
    }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:16) {
                if isControl {
                    OathNetworkLogo(asset:"network-"+permission.network,size:56)
                } else {
                    OathWCReviewTokenLogo(networkID:permission.network,
                        reference:permission.identityAddress,symbol:symbol,size:56)
                }
                VStack(alignment:.leading,spacing:6) {
                    Text(verbatim:isControl ? strings.text(.permissionControl)
                        : model.name(permission) ?? WalletPermission.abbreviated(permission.identityAddress))
                        .oathFont(.title3,weight:.semibold)
                    Text(verbatim:OathImportChain(rawValue:permission.network)?.name ?? permission.network)
                        .oathFont(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength:0)
            }.padding(20)
            if let network = EVMSendNetwork(rawValue:permission.network) {
                OathWCSpenderRow(network:network,address:permission.spender,
                    identity:model.identities[permission.spenderIdentityKey],close:{ dismiss() })
            } else {
                NavigationLink {
                    OathWCAddressDetails(address:permission.spender,title:.permissionSpender,close:{ dismiss() })
                } label: {
                    OathSettingsRow(title:strings.text(.permissionSpender),
                        value:model.spenderName(permission) ?? WalletPermission.abbreviated(permission.spender))
                }.buttonStyle(OathSettingsRowButtonStyle())
            }
            OathSettingsRow(title:strings.text(.permissionAccess),value:access,accessory:.none)
            if permission.kind == .collectible, let tokenID = permission.tokenID {
                OathSettingsRow(title:strings.text(.permissionTokenID),value:tokenID,accessory:.none)
            }
            OathSettingsRow(title:strings.text(.permissionAfter),
                value:strings.text(permission.kind == .permit2Nonce ? .permissionNonceAdvanced:.permissionNone),accessory:.none)
            if !isControl {
                NavigationLink {
                    OathWCAddressDetails(address:permission.identityAddress,title:.permissionContract,close:{ dismiss() })
                } label: {
                    OathSettingsRow(title:strings.text(.permissionContract),
                        value:WalletPermission.abbreviated(permission.identityAddress))
                }.buttonStyle(OathSettingsRowButtonStyle())
            }
        }.accessibilityIdentifier("permissions.removal.summary")
    }
}
