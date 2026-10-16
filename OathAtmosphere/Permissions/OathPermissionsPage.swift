import SwiftUI
import OathAnkr
import OathDatabase
import OathDiagnostics
import OathNativeRefresh

struct OathPermissionsPage: View {
    let session:OathWalletSession
    @State private var model=OathPermissionsModel()
    @Environment(\.oathLocalizer) private var strings
    @State private var connections=OathWalletConnectService.shared
    var body:some View {
        OathPermissionContent(refreshAction: { await model.refresh(session:session) },
            refreshIdentity: model.walletID, refreshEnabled: session.isUnlocked && !session.changingWallet) {
            Menu {
                ForEach(session.wallets,id:\.id) { wallet in
                    Button(session.walletName(wallet,strings:strings)) { model.walletID=wallet.id }
                }
            } label: { OathSettingsRow(title:session.walletName(session.wallets.first{$0.id==model.walletID},strings:strings),icon:"wallet.bifold",accessory:.none) }
                .buttonStyle(OathSettingsRowButtonStyle())
            OathSettingsFooter { Text(strings.text(.permissionIntro)) }
            OathSettingsSectionRule()
            category(.permissionTokens,icon:"hand.raised",kinds:[.token,.permit2,.delegate])
            category(.permissionCollectibles,icon:"square.stack",kinds:[.collectible,.collection])
            NavigationLink { OathWalletConnectPage(session:session,walletID:model.walletID) } label: {
                OathSettingsRow(title:strings.text(.permissionConnections),icon:"link",value:strings.number(connections.sessions.filter{connections.walletID(for:$0.topic)==model.walletID}.count))
            }.buttonStyle(OathSettingsRowButtonStyle())
            category(.permissionControl,icon:"person.badge.key",kinds:[.accountControl,.delegation,.permanentDelegate])
            OathSettingsSectionRule()
            NavigationLink { OathPermissionHistoryPage(session:session,model:model) } label: { OathSettingsRow(title:strings.text(.permissionHistory),icon:"clock.arrow.circlepath") }.buttonStyle(OathSettingsRowButtonStyle())
            NavigationLink { coverage } label: { OathSettingsRow(title:strings.text(.permissionCoverage),icon:"checkmark.shield",isWorking:!model.scanning.isEmpty) }.buttonStyle(OathSettingsRowButtonStyle())
            NavigationLink { help } label: { OathSettingsRow(title:strings.text(.permissionHelp),icon:"questionmark.circle") }.buttonStyle(OathSettingsRowButtonStyle())
            if model.failure { OathSettingsFooter { Text(strings.text(.permissionUnavailable)) } }
        }
        .onAppear { if model.walletID.isEmpty { model.walletID=session.portfolio?.wallet.id ?? "" };connections.configure(session:session);connections.refreshSessions() }
        .task(id:model.walletID+String(session.isUnlocked)) { if !model.walletID.isEmpty,session.isUnlocked { await model.load(session:session) } }
        .toolbar { ToolbarItem(placement:.topBarTrailing) { if model.scanning.isEmpty { Button { Task { await model.refresh(session:session) } } label: { Image(systemName:"arrow.clockwise") }.accessibilityLabel(strings.text(.permissionScan)).oathNeutralControl() } else { ProgressView().tint(.secondary) } } }
        .navigationTitle(strings.text(.permissions)).navigationBarTitleDisplayMode(.inline)
        .oathNativeLocalization()
    }
    private func category(_ title:OathStringKey,icon:String,kinds:Set<WalletPermission.Kind>)->some View {
        NavigationLink { OathPermissionList(session:session,model:model,title:title,kinds:kinds) } label: {
            OathSettingsRow(title:strings.text(title),icon:icon,value:strings.number(model.permissions.filter{kinds.contains($0.kind)}.count))
        }.buttonStyle(OathSettingsRowButtonStyle())
    }
    private var coverage:some View {
        OathPermissionContent {
            ForEach(model.accounts,id:\.id) { account in
                let scan=model.scans[account.networkID]
                OathSettingsRow(title:OathImportChain(rawValue:account.networkID)?.name ?? account.networkID,
                    value:scan.map{strings.text(Self.coverageTitle($0.coverage))} ?? "—",accessory:.none,
                    subtitle:scan.map{$0.checkedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(strings.language.locale))},networkLogo:"network-"+account.networkID,isWorking:model.scanning.contains(account.networkID))
            }
            OathSettingsSectionRule()
            OathSettingsFooter { Text(strings.text(.permissionCoverageDetail)) }
            NavigationLink { OathPermissionContractPage(session:session,model:model) } label: { OathSettingsRow(title:strings.text(.permissionCheck),icon:"doc.text.magnifyingglass") }.buttonStyle(OathSettingsRowButtonStyle())
        }.navigationTitle(strings.text(.permissionCoverage))
    }
    static func coverageTitle(_ c:PermissionScan.Coverage)->OathStringKey {
        switch c { case .checked:.permissionChecked;case .partial:.permissionPartial;case .unavailable:.permissionUnavailable;case .unsupported:.permissionNotIndexed }
    }
    private var help:some View {
        OathPermissionContent {
            OathSettingsFooter { Text(strings.text(.permissionIntro)) }
            OathSettingsSectionRule()
            OathSettingsRow(title:strings.text(.permissionKnownSignatures),icon:"signature",accessory:.none)
            OathSettingsFooter { Text(strings.text(.permissionSignatureHelp)) }
            OathSettingsSectionRule()
            OathSettingsFooter { Text(strings.text(.permissionCoverageDetail)) }
            OathSettingsFooter { Text(strings.text(.permissionDeviceHelp)) }
            Button { if let url=URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } label: { OathSettingsRow(title:strings.text(.permissionOpenSettings),icon:"gear") }.buttonStyle(OathSettingsRowButtonStyle())
        }.navigationTitle(strings.text(.permissionHelp))
    }
}

struct OathPermissionContent<Content:View>:View {
    var refreshAction: (@MainActor @Sendable () async throws -> Void)? = nil
    var refreshIdentity: String? = nil
    var refreshEnabled = true
    @ViewBuilder let content:()->Content
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        Group {
            if let refreshAction {
                NativeRefreshScroll(identifier: "permissions.scroll", tint: .label,
                    labels: NativeRefreshLabels(pull: strings.text(.pullToRefresh), refreshing: strings.text(.refreshing),
                        succeeded: strings.text(.refreshSucceeded), failed: strings.text(.refreshFailed)),
                    isEnabled: refreshEnabled, refreshIdentity: refreshIdentity,
                    action: refreshAction, onFailure: {}, onScroll: { _ in }) {
                    Color.clear.frame(height: 12).accessibilityHidden(true)
                    content().frame(maxWidth: 700).frame(maxWidth: .infinity)
                    Color.clear.frame(height: 12).accessibilityHidden(true)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, content: content).padding(.vertical, 12)
                        .frame(maxWidth: 700).frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea()).oathFont(.body)
    }
}
extension WalletPermission {
    var removable:Bool { [.token,.collectible,.collection,.permit2,.permit2Nonce,.delegate,.accountControl,.delegation].contains(kind) }
    var kindTitle:OathStringKey {
        switch kind { case .token:amount=="115792089237316195423570985008687907853269984665640564039457584007913129639935" ? .permissionUnlimited:.permissionLimited;case .collectible:.permissionOneItem;case .collection:.permissionAllItems;case .permit2:.permissionAccess;case .permit2Nonce:.permissionNonce;case .delegate:.permissionDelegate;case .permanentDelegate:.permissionPermanent;case .accountControl,.delegation:.permissionControl }
    }
    static func abbreviated(_ value:String)->String { value.count>24 ? String(value.prefix(10))+"…"+String(value.suffix(8)):value }
}

private struct OathPermissionList: View {
    let session:OathWalletSession,model:OathPermissionsModel,title:OathStringKey,kinds:Set<WalletPermission.Kind>
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query=""
    @State private var selected=Set<String>()
    @State private var networks=Set<String>()
    @State private var selecting=false
    @State private var filters=false
    @State private var reviewing=false
    @State private var reviewItems=[WalletPermission]()
    @State private var batchItems=[PermissionBatchItem]()
    @State private var batchFailure=false
    @State private var batchIndex=[String:PermissionBatchItem]()
    @State private var activePermissions=Set<String>()
    private var coordinator:OathPermissionBatchCoordinator { .shared }
    private var isRunning:Bool { coordinator.runningWalletID==model.walletID }
    private var readOnly:Bool { session.wallets.first{$0.id==model.walletID}?.kind=="watchOnly" }
    private var items:[WalletPermission] { model.permissions.filter { p in
        kinds.contains(p.kind) && !verifiedRemoved(p) && (networks.isEmpty || networks.contains(p.network)) && (query.isEmpty || [p.contract,p.spender,p.identityAddress,model.name(p) ?? "",model.identity(p)?.symbol ?? "",model.spenderName(p) ?? "",p.network].contains{$0.localizedCaseInsensitiveContains(query)})
    } }
    private var grouped:[String:[WalletPermission]] { Dictionary(grouping:items,by:\.network) }
    private var selectable:Set<String> { Set(items.filter { canRemove($0) }.map(\.id)) }
    private var allSelected:Bool { !selectable.isEmpty && selected==selectable }
    private var latest:[PermissionBatchItem] {
        guard let id=batchItems.first?.batchID else { return [] }
        return batchItems.filter{$0.batchID==id}
    }
    private var progressTitle:String {
        let key:OathStringKey=coordinator.runningWalletID==model.walletID ? .sendPreparing:.permissionHistory
        return strings.text(key)
    }
    private var progressCount:String {
        let completed=latest.filter { item in item.state != "queued" && item.state != "processing" }.count
        return strings.number(completed)+" / "+strings.number(latest.count)
    }
    private var permissionList:some View {
        let groups=grouped
        return List(selection:$selected) {
            if !latest.isEmpty {
                Section {
                    NavigationLink { batchResults } label: {
                        OathSettingsRow(title:progressTitle,value:progressCount,accessory:.none)
                    }.selectionDisabled().listRowBackground(Color.clear)
                }
            }
            ForEach(groups.keys.sorted { networkName($0).localizedStandardCompare(networkName($1)) == .orderedAscending },id:\.self) { network in
                networkSection(network,permissions:groups[network] ?? [])
            }
            if items.isEmpty {
                Section {
                    OathEmptyState(strings.text(query.isEmpty ? .permissionEmpty:.permissionNoResults),systemImage:"hand.raised",description:strings.text(.permissionEmptyDetail))
                        .selectionDisabled().listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
            }
            if !selecting {
                Section {
                    NavigationLink { OathPermissionContractPage(session:session,model:model) } label: {
                        OathSettingsRow(title:strings.text(.permissionCheck),icon:"doc.text.magnifyingglass",accessory:.none)
                    }.selectionDisabled().listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
            }
            if batchFailure { Text(strings.text(.permissionError)).foregroundStyle(.red).selectionDisabled() }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .environment(\.editMode,.constant(selecting ? .active:.inactive))
        .tint(OathOnboardingColors.blue)
        .background(Color(uiColor:OathSurfaceColors.canvas).ignoresSafeArea())
        .searchable(text:$query,prompt:strings.text(.permissionSearch))
        .navigationTitle(strings.text(title)).navigationBarTitleDisplayMode(.inline)
        .animation(reduceMotion ? nil:.default,value:items.map(\.id))
    }
    var body:some View {
        permissionList
        .toolbar {
            if selecting {
                ToolbarItem(placement:.topBarLeading) {
                    OathButton(strings.text(allSelected ? .deselectAllWallets:.selectAllWallets)) {
                        selected=allSelected ? []:selectable
                    }.oathNeutralControl().disabled(selectable.isEmpty)
                }
                ToolbarItem(placement:.topBarTrailing) { OathDoneButton { selecting=false;selected=[] } }
            } else {
                ToolbarItem(placement:.topBarTrailing) { Menu {
                    Button(strings.text(.permissionSelect)) { selecting=true;selected=[] }.disabled(readOnly || selectable.isEmpty)
                    Button(strings.text(.historyNetworks)) { filters=true }
                } label: { Image(systemName:"line.3.horizontal.decrease") }.oathNeutralControl() }
            }
        }
        .oathBottomActions(isPresented:selecting) {
            OathActionButton(title:strings.text(.permissionRevokeAll),icon:"hand.raised.slash",role:.destructive,accent:.red) {
                review(items.filter{selected.contains($0.id)})
            }.disabled(selected.isEmpty || coordinator.runningWalletID != nil || !session.isUnlocked)
        }
        .sheet(isPresented:$filters) { OathPermissionNetworkFilter(networks:model.accounts.map(\.networkID),selection:$networks) }
        .sheet(isPresented:$reviewing) { OathPermissionBatchReview(session:session,model:model,items:reviewItems) }
        .onChange(of:selectable) { _,allowed in selected.formIntersection(allowed) }
        .onChange(of:isRunning) { _,running in
            if running { selecting=false;selected.removeAll() }
        }
        .task(id:model.identityRequestKey) { await model.resolveIdentities(session:session) }
        .task(id:model.walletID) { await observeBatches() }
        .task(id:model.walletID+String(coordinator.runningWalletID==model.walletID)) { await observeHistory() }
    }
    private func networkSection(_ network:String,permissions:[WalletPermission])->some View {
        Section {
            ForEach(permissions) { permission in permissionListRow(permission) }
        } header: {
            HStack(spacing:8) {
                OathNetworkLogo(asset:"network-"+network,size:22)
                Text(networkName(network)).oathFont(.subheadline,weight:.semibold)
            }.textCase(nil).padding(.vertical,8)
        }
    }
    private func permissionListRow(_ permission:WalletPermission)->some View {
        permissionCell(permission)
            .tag(permission.id)
            .selectionDisabled(!canRemove(permission))
            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
            .swipeActions(edge:.trailing,allowsFullSwipe:false) {
                if !selecting,canRemove(permission) {
                    Button(role:.destructive) { review([permission]) } label: {
                        Label(strings.text(.permissionRemove),systemImage:"hand.raised.slash")
                    }.disabled(coordinator.runningWalletID != nil)
                }
            }
    }
    @ViewBuilder private func permissionCell(_ permission:WalletPermission)->some View {
        if selecting { permissionRow(permission) }
        else {
            NavigationLink { OathPermissionDetail(session:session,model:model,permission:permission) } label: {
                permissionRow(permission)
            }.buttonStyle(OathSettingsRowButtonStyle())
        }
    }
    private func permissionRow(_ permission:WalletPermission)->some View {
        let item=batchIndex[permission.id]
        let status=item.flatMap { $0.state=="removed" && !verifiedRemoved(permission) ? nil:strings.text(Self.statusKey($0)) }
        return OathSettingsRow(title:model.name(permission) ?? WalletPermission.abbreviated(permission.identityAddress),accessory:.none,
            subtitle:(model.spenderName(permission) ?? WalletPermission.abbreviated(permission.spender))+"\n"+(status ?? strings.text(permission.kindTitle)),
            networkLogo:"network-"+permission.network)
    }
    private func verifiedRemoved(_ permission:WalletPermission)->Bool {
        guard let item=batchIndex[permission.id],item.state=="removed",
              let verified=item.verifiedAt,let scan=model.scans[permission.network] else { return false }
        return scan.checkedAt.timeIntervalSince1970<=verified
    }
    private func canRemove(_ permission:WalletPermission)->Bool {
        !readOnly && permission.removable && !activePermissions.contains(permission.id)
    }
    private func networkName(_ network:String)->String { OathImportChain(rawValue:network)?.name ?? network }
    private func review(_ permissions:[WalletPermission]) { reviewItems=permissions;reviewing=true }
    private var batchResults:some View {
        OathPermissionContent {
            OathSettingsFooter { Text(strings.text(.permissionBatchDetail)) }
            ForEach(latest) { item in
                OathSettingsRow(title:model.name(item.permission) ?? WalletPermission.abbreviated(item.permission.identityAddress),
                    accessory:.none,subtitle:strings.text(Self.statusKey(item)),networkLogo:"network-"+item.permission.network,
                    isWorking:coordinator.runningWalletID==model.walletID && ["queued","processing"].contains(item.state))
            }
            if latest.contains(where:{$0.retryable}),coordinator.runningWalletID==nil {
                Button { review(latest.filter(\.retryable).map(\.permission)) } label: {
                    OathSettingsRow(title:strings.text(.tryAgain),icon:"arrow.clockwise")
                }.buttonStyle(OathSettingsRowButtonStyle())
                OathSettingsFooter { Text(strings.text(.permissionBatchPaused)) }
            }
            NavigationLink { OathPermissionHistoryPage(session:session,model:model) } label: {
                OathSettingsRow(title:strings.text(.permissionHistory),icon:"clock.arrow.circlepath")
            }.buttonStyle(OathSettingsRowButtonStyle())
        }.navigationTitle(strings.text(.permissionSelection)).navigationBarTitleDisplayMode(.inline)
    }
    static func statusKey(_ item:PermissionBatchItem)->OathStringKey {
        switch item.state {
        case "queued","processing":return .sendPreparing
        case "submitted":return .permissionPending
        case "removed":return .permissionRemoved
        case "alreadyRemoved":return .permissionAlready
        case "active":return .permissionStillActive
        case "paused":return .permissionBatchPaused
        case "cancelled":return .assetCanceled
        case "replaced":return .assetReplaced
        case "expired":return .permissionExpired
        default:return item.errorCode==nil ? .permissionFailed:OathPermissionBatchReview.failureKey(item)
        }
    }
    private func observeBatches() async {
        let walletID=model.walletID
        do {
            let db=try await session.vault.database()
            try await db.reconcilePermissionBatches(walletID:walletID,interruptUnsigned:coordinator.runningWalletID != walletID)
            var initial=true, removed=Set<String>()
            for try await values in db.observePermissionBatchItems(walletID:walletID) {
                guard !Task.isCancelled,model.walletID==walletID else { return }
                let confirmed=Set(values.filter{$0.state=="removed"}.map(\.id))
                if !initial,!confirmed.subtracting(removed).isEmpty { OathHaptics.shared.play(.success) }
                initial=false;removed=confirmed;batchItems=values
                batchIndex=Dictionary(values.map{($0.permission.id,$0)},uniquingKeysWith:{first,_ in first})
                activePermissions=Set(values.filter{["queued","processing","submitted"].contains($0.state)}.map{$0.permission.id})
                for item in values where item.state=="removed" {
                    guard let scan=model.scans[item.permission.network],let verified=item.verifiedAt,
                          scan.checkedAt.timeIntervalSince1970<=verified else { continue }
                    model.scans[scan.network] = .init(network:scan.network,owner:scan.owner,
                        permissions:scan.permissions.filter{$0.id != item.permission.id},coverage:scan.coverage,checkedAt:scan.checkedAt)
                }
            }
        } catch {
            if !Task.isCancelled { OathDiagnostics.record(error,component:"permissions",operation:"batch_observe");batchFailure=true }
        }
    }
    private func observeHistory() async {
        let walletID=model.walletID
        do {
            let db=try await session.vault.database()
            for try await history in db.observePermissionHistory(walletID:walletID) {
                guard !Task.isCancelled,model.walletID==walletID else { return }
                model.history=history
                try await db.reconcilePermissionBatches(walletID:walletID,interruptUnsigned:coordinator.runningWalletID != walletID)
            }
        } catch {
            if !Task.isCancelled { OathDiagnostics.record(error,component:"permissions",operation:"batch_reconcile");batchFailure=true }
        }
    }
}

private struct OathPermissionNetworkFilter:View {
    let networks:[String]
    @Binding var selection:Set<String>
    @State private var draft=Set<String>()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings
    var body:some View {
        NavigationStack {
            OathPermissionContent {
                Button { draft=[] } label: { OathSettingsRow(title:strings.text(.assetFilterAllNetworks),accessory:.selection(draft.isEmpty)) }.buttonStyle(OathSettingsRowButtonStyle())
                ForEach(Array(Set(networks)).sorted(),id:\.self) { network in
                    Button { if draft.contains(network) { draft.remove(network) } else { draft.insert(network) } } label: { OathSettingsRow(title:OathImportChain(rawValue:network)?.name ?? network,accessory:.selection(draft.contains(network)),networkLogo:"network-"+network) }.buttonStyle(OathSettingsRowButtonStyle())
                }
            }.navigationTitle(strings.text(.historyNetworks)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { OathCloseButton { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { OathDoneButton { selection=draft;dismiss() }.disabled(draft==selection) }
            }
        }.onAppear{draft=selection}.presentationDetents([.large]).presentationDragIndicator(.visible).presentationBackground(Color(uiColor:OathSurfaceColors.canvas)).oathNativeLocalization()
    }
}

private struct OathPermissionDetail:View {
    let session:OathWalletSession,model:OathPermissionsModel,permission:WalletPermission
    @Environment(\.oathLocalizer) private var strings
    @State private var permitBlock:WalletPermission?
    @State private var error:OathStringKey?
    @State private var checking=false
    private var readOnly:Bool { session.wallets.first{$0.id==model.walletID}?.kind=="watchOnly" }
    var body:some View {
        OathPermissionContent {
            VStack(spacing:14) {
                OathNetworkLogo(asset:"network-"+permission.network,size:56)
                Text(model.name(permission) ?? WalletPermission.abbreviated(permission.identityAddress)).oathFont(.title2,weight:.semibold)
                Text(OathImportChain(rawValue:permission.network)?.name ?? permission.network).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity).padding(28)
            value(.permissionContract,permission.contract)
            value(.permissionSpender,permission.spender,name:model.spenderName(permission))
            if let id=permission.tokenID { value(.permissionTokenID,id) }
            if let account=permission.tokenAccount { value(.contactAddress,account) }
            OathSettingsSectionRule()
            OathSettingsRow(title:strings.text(.permissionAccess),value:strings.text(permission.kindTitle),accessory:.none)
            if permission.kind == .token || permission.kind == .delegate {
                OathSettingsRow(title:strings.text(.sendAmount),value:allowance,accessory:.none)
            }
            if permission.kind == .permanentDelegate { footer(.permissionPermanentDetail) }
            else if !permission.removable { footer(.permissionUnsupported) }
            else if readOnly { footer(.permissionReadOnly) }
            else {
                if permission.kind == .permit2 { footer(.permissionPermitDetail) }
                NavigationLink { OathPermissionReview(session:session,model:model,permission:permission) } label: { OathSettingsRow(title:strings.text(.permissionRemove),icon:"hand.raised.slash",color:.red) }.buttonStyle(OathSettingsRowButtonStyle())
            }
            if permission.kind == .permit2,!readOnly {
                NavigationLink {
                    OathPermissionReview(session:session,model:model,permission:.init(network:permission.network,owner:permission.owner,contract:permission.contract,spender:permission.spender,kind:.permit2Nonce,amount:permission.amount,tokenID:permission.tokenID))
                } label:{OathSettingsRow(title:strings.text(.permissionNonce),icon:"signature")}.buttonStyle(OathSettingsRowButtonStyle())
                footer(.permissionNonceDetail)
                Button { blockPermit() } label:{OathSettingsRow(title:strings.text(.permissionPermitBlock),icon:"hand.raised.slash",isWorking:checking)}.buttonStyle(OathSettingsRowButtonStyle()).disabled(checking)
            }
            if let error { footer(error) }
        }.navigationTitle(strings.text(.permissionAccess)).navigationBarTitleDisplayMode(.inline)
        .task(id:permission.id) { await model.resolveIdentities(session:session,items:[permission]) }
        .navigationDestination(isPresented:Binding(get:{permitBlock != nil},set:{if !$0 {permitBlock=nil}})) {
            if let permitBlock { OathPermissionReview(session:session,model:model,permission:permitBlock) }
        }
    }
    private var allowance:String {
        if permission.kindTitle == .permissionUnlimited { return strings.text(.permissionUnlimited) }
        if let decimals=model.identity(permission)?.decimals ?? model.holding(permission)?.decimals,
           let symbol=model.identity(permission)?.symbol ?? model.holding(permission)?.symbol,
           let units=OathSendAmount.units(permission.amount,decimals:decimals) { return units+" "+symbol }
        return permission.amount+" "+strings.text(.permissionAtomic)
    }
    private func value(_ key:OathStringKey,_ value:String,name:String?=nil)->some View {
        Button { UIPasteboard.general.string=value;OathHaptics.shared.play(.selection) } label:{
            VStack(alignment:.leading,spacing:8) { Text(strings.text(key)).oathFont(.subheadline).foregroundStyle(.secondary);if let name {Text(name)};OathAddressText(address:value,centered:false) }.padding(20)
        }.buttonStyle(.plain).accessibilityHint(strings.text(.copyAddress))
    }
    private func footer(_ key:OathStringKey)->some View { OathSettingsFooter { Text(strings.text(key)) } }
    private func blockPermit() {
        guard let account=model.account(permission),let token=permission.tokenID else { return };checking=true;error=nil
        Task { do { permitBlock=try await OathPermissionService.shared.checkContract(account:account,contract:token,spender:EVMPermissionRemoval.permit2,kind:.token,tokenID:nil) }
            catch { self.error = .permissionError;OathDiagnostics.record(error,component:"permissions",operation:"permit2_scope",context:["chain":permission.network]) };checking=false }
    }
}

