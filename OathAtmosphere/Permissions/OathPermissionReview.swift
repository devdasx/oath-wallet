import SwiftUI
import OathAnkr
import OathDatabase
import OathDiagnostics

enum OathPermissionReview {
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
