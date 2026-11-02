import SwiftUI
import OathAnkr
import OathDatabase
import OathDiagnostics

struct OathPermissionContractPage:View {
    let session:OathWalletSession,model:OathPermissionsModel
    @Environment(\.oathLocalizer) private var strings
    @State private var network=""
    @State private var contract=""
    @State private var spender=""
    @State private var tokenID=""
    @State private var kind=EVMPermissionRemoval.Kind.token
    @State private var busy=false
    @State private var error:OathStringKey?
    @State private var found:WalletPermission?
    @State private var revokeAction = OathPermissionRevokeAction()
    @State private var focused: Field?
    private enum Field: String { case contract, spender, tokenID }
    private var needsID:Bool { [.collectible,.permit2,.permit2Nonce].contains(kind) }
    private var networks: [String] {
        Array(Set(model.accounts.map(\.networkID)))
            .filter { (EVMSendNetwork(rawValue: $0) != nil) || $0 == "tron" }
            .sorted { networkName($0) < networkName($1) }
    }
    private var canCheck: Bool {
        !busy && validLookupInput && !contract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !spender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!needsID || !tokenID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && networks.contains(network)
    }
    private var validLookupInput: Bool {
        if network == "tron" {
            return TronIdentity.isAddress(contract.trimmingCharacters(in: .whitespacesAndNewlines))
                && TronIdentity.isAddress(spender.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (try? PermissionCheckInput.evm(kind: kind, contract: contract,
                                             spender: spender, tokenID: tokenID)) != nil
    }
    var body:some View {
        OathPermissionContent {
            NavigationLink {
                OathPermissionContractChoices(title: .tokenNetwork, choices: networks, selection: $network,
                    titleForChoice: networkName, logoForChoice: { "network-" + $0 })
            } label: {
                OathSettingsRow(title: strings.text(.tokenNetwork), icon: "network",
                    value: network.isEmpty ? nil : networkName(network),
                    networkLogo: network.isEmpty ? nil : "network-" + network)
            }
            .buttonStyle(OathSettingsRowButtonStyle())
            .accessibilityIdentifier("permissions.check.network")
            if network != "tron" {
                NavigationLink {
                    OathPermissionContractChoices(title: .permissionType,
                        choices: [.token, .collectible, .collection, .permit2, .permit2Nonce],
                        selection: $kind, titleForChoice: kindName)
                } label: {
                    OathSettingsRow(title: strings.text(.permissionType), icon: "hand.raised",
                        value: kindName(kind))
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("permissions.check.type")
            }
            OathInputGroup {
                field(.permissionContract, text: $contract, field: .contract)
                OathInputSeparator()
                field(.permissionSpender, text: $spender, field: .spender)
                if needsID {
                    OathInputSeparator()
                    field(.permissionTokenID, text: $tokenID, field: .tokenID)
                }
            }
            .padding(20)
            OathSettingsFooter { Text(strings.text(.permissionCoverageDetail)) }
            if let found {
                OathSettingsSectionRule()
                OathPermissionRemovalSummary(model:model,permission:found)
                Button(role:.destructive) {
                    revokeAction.revoke([found],session:session,model:model,reason:strings.text(.permissionRemove))
                } label: {
                    HStack {
                        Text(strings.text(.permissionRemove))
                        if revokeAction.pending.contains(found.id) || pending(found) { ProgressView() }
                    }.frame(minHeight:44)
                }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                .disabled(!OathPermissionBatchCoordinator.shared.canStart || pending(found) || !session.isUnlocked ||
                          session.wallets.first(where:{$0.id == model.walletID})?.kind == "watchOnly")
            }
            if let found, let item=latestItems[found.id], item.retryable {
                OathSettingsFooter { Text(strings.text(OathPermissionBatchReview.failureKey(item))).foregroundStyle(.red) }
            }
            if let failure=revokeAction.failure { OathSettingsFooter { Text(strings.text(failure)).foregroundStyle(.red) } }
            if let error { OathSettingsFooter { Text(strings.text(error)) } }
        }.disabled(busy).navigationTitle(strings.text(.permissionCheck)).navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar { ToolbarItem(placement:.topBarTrailing) {
            if busy { ProgressView() }
            else { OathDoneButton(label: .permissionCheck) { check() }.disabled(!canCheck) }
        } }
        .onAppear { if network.isEmpty { network=model.accounts.first(where:{(EVMSendNetwork(rawValue:$0.networkID) != nil) || $0.networkID=="tron"})?.networkID ?? "" } }
        .onChange(of:network) { _,_ in if network=="tron" {kind = .token};found=nil;error=nil }
        .onChange(of: kind) { _, _ in
            found = nil; error = nil
            if !needsID, focused == .tokenID { focused = nil }
        }
        .onChange(of:contract) { _,_ in found=nil;error=nil }
        .onChange(of:spender) { _,_ in found=nil;error=nil }
        .onChange(of:tokenID) { _,_ in found=nil;error=nil }
        .onChange(of:model.walletID) { _,_ in found=nil;pendingIDs=[];latestItems=[:] }
        .onChange(of:revokeAction.verifiedAbsent) { _,ids in
            if let found, ids.contains(found.id) { withAnimation { self.found=nil } }
        }
        .onDisappear { focused = nil }
        .modifier(OathPermissionAuthentication(action:revokeAction,session:session,model:model))
        .task(id:model.walletID) { await observeRevocations() }
        .task(id:model.walletID) { await reconcileRevocations() }
    }
    private func pending(_ permission:WalletPermission)->Bool {
        pendingIDs.contains(permission.id)
    }
    @State private var pendingIDs=Set<String>()
    @State private var latestItems=[String:PermissionBatchItem]()
    private func observeRevocations() async {
        let walletID=model.walletID
        do {
            let db=try await session.vault.database()
            for try await batch in db.observePermissionBatchItems(walletID:walletID) {
                guard !Task.isCancelled,model.walletID == walletID else { return }
                pendingIDs=Set(batch.filter{["queued","processing","submitted"].contains($0.state)}.map{$0.permission.id})
                latestItems=Dictionary(batch.map{($0.permission.id,$0)},uniquingKeysWith:{first,_ in first})
                if let found, !pending(found), let item=latestItems[found.id], ["removed","alreadyRemoved"].contains(item.state),
                   let verified=item.verifiedAt, let scan=model.scans[found.network],
                   scan.checkedAt.timeIntervalSince1970 <= verified {
                    withAnimation {
                        model.scans[found.network] = .init(network:scan.network,owner:scan.owner,
                            permissions:scan.permissions.filter{$0.id != found.id},coverage:scan.coverage,checkedAt:scan.checkedAt)
                        self.found=nil
                    }
                }
            }
        } catch {
            if !Task.isCancelled { OathDiagnostics.record(error,component:"permissions",operation:"contract_observe");self.error = .permissionError }
        }
    }

    private func reconcileRevocations() async {
        let walletID=model.walletID
        do {
            let db=try await session.vault.database()
            for try await history in db.observePermissionHistory(walletID:walletID) {
                guard !Task.isCancelled,model.walletID == walletID else { return }
                model.history=history
                try await db.reconcilePermissionBatches(walletID:walletID,interruptUnsigned:OathPermissionBatchCoordinator.shared.runningWalletID != walletID)
            }
        } catch {
            if !Task.isCancelled { OathDiagnostics.record(error,component:"permissions",operation:"contract_reconcile");self.error = .permissionError }
        }
    }
    private func networkName(_ id: String) -> String {
        strings.invariant(OathImportChain(rawValue: id)?.name ?? id)
    }
    private func kindName(_ value: EVMPermissionRemoval.Kind) -> String {
        switch value {
        case .token: strings.text(.permissionTokens)
        case .collectible: strings.text(.permissionOneItem)
        case .collection: strings.text(.permissionAllItems)
        case .permit2: strings.invariant("Permit2")
        case .permit2Nonce: strings.text(.permissionNonce)
        case .delegation: strings.text(.permissionControl)
        }
    }
    private func field(_ title: OathStringKey, text: Binding<String>, field: Field) -> some View {
        let next: Field? = field == .contract ? .spender : (field == .spender && needsID ? .tokenID : nil)
        return OathPasteInput(hasText: !text.wrappedValue.isEmpty,
            identifier: "permissions.check.\(field.rawValue).paste",
            clearIdentifier: "permissions.check.\(field.rawValue).clear", onPaste: {
                guard !busy, session.isUnlocked else { return }
                if let value = OathClipboard.paste() {
                    text.wrappedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    error = nil; focused = field
                }
            }, onClear: {
                guard !busy, session.isUnlocked else { return }
                text.wrappedValue = ""; error = nil; focused = field
            }) {
                OathTextInput(text: text, focused: Binding(get: { focused == field }, set: { value in
                    if value { focused = field }
                    else if focused == field { focused = nil }
                }), title: strings.text(title), identifier: "permissions.check.\(field.rawValue)",
                    address: true, returnKeyType: next == nil ? .done : .next) {
                        if let next { focused = next }
                        else if canCheck { check() }
                    }
            }
    }
    private func check() {
        guard canCheck, session.isUnlocked else { return }
        guard let account=model.accounts.first(where:{$0.networkID==network}) else { return }
        focused = nil
        busy=true;error=nil
        let c=contract.trimmingCharacters(in:.whitespacesAndNewlines),s=spender.trimmingCharacters(in:.whitespacesAndNewlines),id=needsID ? tokenID.trimmingCharacters(in:.whitespacesAndNewlines):nil,requestedKind=kind
        Task {
            do {
                let value=try await OathPermissionService.shared.checkContract(account:account,contract:c,spender:s,kind:requestedKind,tokenID:id)
                guard session.isUnlocked,model.walletID==account.walletID,network==account.networkID else { busy=false;return }
                let previous=model.scans[account.networkID]
                let scan=PermissionScan(network:account.networkID,owner:value.owner,permissions:(previous?.permissions.filter{$0.id != value.id} ?? [])+[value],coverage:previous?.coverage ?? .partial,checkedAt:previous?.checkedAt ?? .now)
                try await session.vault.database().savePermissionScan(walletID:account.walletID,accountID:account.id,scan:scan)
                guard session.isUnlocked,model.walletID==account.walletID,network==account.networkID else {busy=false;return}
                model.scans[account.networkID]=scan;found=value
            } catch {
                self.error=OathPermissionReview.message(error)
                // Invalid form values and absent approvals are expected user input, not failures.
                if ![PermissionError.alreadyRemoved,.malformed].contains(error as? PermissionError ?? .unavailable),error as? EVMSendError != .malformed,error as? EVMSendError != .amount { OathDiagnostics.record(error,component:"permissions",operation:"check_contract",context:["chain":account.networkID]) }
            };busy=false
        }
    }
}

/// Use the same disclosure navigation and blue selection check as Settings.
private struct OathPermissionContractChoices<Choice: Hashable>: View {
    let title: OathStringKey
    let choices: [Choice]
    @Binding var selection: Choice
    let titleForChoice: (Choice) -> String
    var logoForChoice: (Choice) -> String? = { _ in nil }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        OathPermissionContent {
            ForEach(choices, id: \.self) { choice in
                OathButton(feedback: .selection) {
                    selection = choice
                    dismiss()
                } label: {
                    OathSettingsRow(title: titleForChoice(choice), accessory: .selection(selection == choice),
                        networkLogo: logoForChoice(choice))
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityAddTraits(selection == choice ? .isSelected : [])
            }
        }
        .navigationTitle(strings.text(title))
        .navigationBarTitleDisplayMode(.inline)
        .oathNativeLocalization()
    }
}
