import SwiftUI
import OathDatabase
import OathDiagnostics
import OathAnkr
@preconcurrency import WalletConnectSign

struct OathWalletConnectSheet: View {
    let uri: String?
    let session: OathWalletSession?
    var onProposalRejected: (() -> Void)? = nil
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var service = OathWalletConnectService.shared
    @State private var walletID = ""
    @State private var accounts = [AccountRecord]()
    @State private var loadingAccounts = true
    @State private var selected = Set<String>()
    @State private var acknowledged = false
    @State private var signing = false
    @State private var passcode = false
    @State private var digits = [UInt8]()
    @State private var notice: OathStringKey?
    @State private var signingTask: Task<Void, Never>?
    @State private var presentationID: UUID?
    @State private var disconnectTopic: String?

    private struct CompletionObservation: Equatable {
        let sendID: String?
        let presentationID: UUID?
        let active: Bool
    }

    var body: some View {
        NavigationStack {
            Group {
                if passcode { passcodePage }
                else if let request = service.pendingRequest { message(request) }
                else if let proposal = service.proposal { proposalPage(proposal) }
                else if let completion = service.completion {
                    if completion.selectedChain != nil {
                        OathWCStatePage(title: .wcNetworkChanged, detail: .wcSwitchNetworkDetail,
                            symbol: "checkmark.circle.fill", identity: identity(completion.peer.peer), primary: close)
                    } else if let solana = completion.solana {
                        OathWCSolanaCompletion(submission: solana, close: close)
                    } else if let transaction = completion.transaction {
                        OathWCEVMCompletion(transaction: transaction, identity: identity(completion.peer.peer), close: close)
                    } else { OathWCStatePage(title: completion.isTransaction ? .wcTransactionSigned : .wcSignatureSent,
                        detail: completion.isTransaction ? .wcTransactionSignedDetail : .wcSignatureSentDetail,
                        symbol: "checkmark.circle.fill", identity: identity(completion.peer.peer), primary: close) }
                }
                else if let issue = service.presentationIssue { issuePage(issue) }
                else if service.working || service.preparingRequest {
                    OathWCStatePage(title: .scannerWCLoading, detail: .wcPreparingDetail, symbol: "link", isWorking: true, primary: close)
                }
                else if service.failed {
                    OathEmptyState(title: strings.text(.scannerWCUnavailable), systemImage: "wifi.exclamationmark", description: strings.text(.scannerWCError)) {
                        if let uri, !service.requiresFreshPairing { OathButton(strings.text(.tryAgain)) { Task { await service.pair(uri) } }.oathNeutralControl() }
                    }
                } else { connections }
            }
            .background(Color(uiColor: OathSurfaceColors.canvas))
            .navigationTitle(strings.text(service.pendingRequest.map(requestTitle) ?? (service.completion == nil ? .scannerConnect : .walletConnect)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close).disabled(signing) } }
            .oathNativeLocalization()
        }
        .preferredColorScheme(nil).oathLanguage(strings.language)
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: OathSurfaceColors.canvas))
        .interactiveDismissDisabled(signing || service.proposal != nil || service.pendingRequest != nil)
        .alert(strings.text(.scannerWCDisconnect), isPresented: Binding(
            get: { disconnectTopic != nil }, set: { if !$0 { disconnectTopic = nil } }
        ), presenting: disconnectTopic) { topic in
            OathButton(strings.text(.scannerWCDisconnect), role: .destructive) {
                Task { _ = await service.disconnect(topic) }
            }.accessibilityIdentifier("walletconnect.disconnect.confirm")
            OathButton(strings.text(.cancel), role: .cancel) { }
        } message: { _ in Text(strings.text(.wcDisconnectDetail)) }
        .onAppear { presentationID = service.presentationDidOpen() }
        .task(id: CompletionObservation(sendID: service.completion?.transaction?.sendID,
                                       presentationID: presentationID, active: scenePhase == .active)) {
            guard scenePhase == .active, let presentationID else { return }
            await service.trackTransactionCompletion(presentationID: presentationID)
        }
        .task {
            if let session { service.configure(session: session); walletID = session.displayedProfile?.id.uuidString ?? "" }
            if let uri { await service.pair(uri) } else { service.resumeRequests() }
        }
        .task(id: walletID) {
            let target = walletID
            loadingAccounts = true; accounts = []; selected = []
            let loaded = await service.accounts(walletID: target)
            guard !Task.isCancelled, target == walletID else { return }; accounts = loaded; loadingAccounts = false; updateSelection()
        }
        .onChange(of: service.proposal?.value.id) { _, _ in acknowledged = false; updateSelection() }
        .onChange(of: session?.isUnlocked) { _, unlocked in if unlocked == false { signingTask?.cancel(); digits = []; passcode = false; dismiss() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { signingTask?.cancel(); digits = [] } }
        .onChange(of: service.pendingRequest?.id) { _, _ in notice = nil; passcode = false; digits = [] }
        .onDisappear {
            signingTask?.cancel(); digits = []
            // SwiftUI may finish the outgoing sheet's disappearance after its
            // onDismiss resumes a queued request. Never reject that next sheet.
            service.presentationWillDisappear(presentationID)
        }
    }
    private func updateSelection() {
        guard let proposal = service.proposal else { selected = []; return }
        let available = Set(accounts.flatMap { OathWalletConnectService.blockchains(networkID: $0.networkID).map(\.absoluteString) })
        selected = (OathWalletConnectService.requested(proposal.value, required: true)
            .union(OathWalletConnectService.requested(proposal.value, required: false))).intersection(available)
    }
    private func proposalPage(_ proposal: OathWalletConnectService.Proposal) -> some View {
        let negotiated = try? service.namespaces(for: proposal.value, accounts: accounts, selected: selected)
        let required = OathWalletConnectService.requested(proposal.value, required: true)
        let requested = required.union(OathWalletConnectService.requested(proposal.value, required: false))
        let networks = requested.sorted().map { block -> OathWCNetworkChoice in
            let solana = SolanaSendNetwork(walletConnectChain: block)
            let chain = solana != nil ? OathImportChain.solana : OathImportChain.allCases.first { OathWalletConnectService.blockchain($0)?.absoluteString == block }
            return .init(id: block, name: solana?.walletConnectName ?? chain?.name ?? block, logo: chain.map { "network-" + $0.id },
                address: accounts.first { $0.networkID == chain?.id }?.address, required: required.contains(block))
        }
        let methods = (negotiated ?? [:]).keys.sorted().map { key in
            OathWCMethodGroup(id: key, methods: negotiated?[key]?.methods.sorted() ?? [], events: negotiated?[key]?.events.sorted() ?? [])
        }
        let identity = OathWCIdentity(name: proposal.value.proposer.name, url: proposal.value.proposer.url,
            icons: proposal.value.proposer.icons, origin: proposal.verify?.origin,
            verification: proposal.blocked ? .blocked : proposal.unverified ? .unknown : .matched)
        return OathWalletConnectConsent(identity: identity,
            wallets: session?.wallets.map { .init(id: $0.id, name: session?.walletName($0, strings: strings) ?? "") } ?? [],
            networks: networks, methods: methods, supported: negotiated != nil, loadingAccounts: loadingAccounts,
            working: service.working, failed: service.failed, walletID: $walletID, selected: $selected,
            acknowledged: $acknowledged, approve: {
                Task { await service.approve(accounts: accounts, selected: selected, walletID: walletID, acknowledged: acknowledged) }
            }, reject: { Task { await service.reject(); onProposalRejected?(); dismiss() } }, close: close,
            unavailableMethods: Set(proposal.value.requiredNamespaces.values.flatMap(\.methods)))
    }
    private func close() {
        guard !signing else { return }
        if service.proposal != nil { onProposalRejected?() }
        signingTask?.cancel(); service.rejectRequest(); Task { await service.reject() }; dismiss()
    }
    private var connections: some View {
        Group {
            if service.sessions.isEmpty {
                OathEmptyState(strings.text(.scannerWCNoSessions), systemImage: "link", description: strings.text(.scannerWCDetail))
            } else if let topic = service.connectedTopic, let peer = service.sessions.first(where: { $0.topic == topic }) {
                OathWCStatePage(title: .scannerWCConnected, detail: .scannerWCConnectedDetail,
                    symbol: "checkmark.circle.fill", identity: identity(peer.peer), primary: close)
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        if service.connectedTopic != nil {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(OathOnboardingColors.blue)
                            Text(strings.text(.scannerWCConnected)).oathFont(.title2, weight: .semibold)
                            Text(strings.text(.scannerWCConnectedDetail)).oathFont(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        ForEach(service.sessions, id: \.topic) { item in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 14) {
                                    OathDAppLogo(icons: item.peer.icons)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(OathWalletConnectPolicy.displayName(item.peer.name)).oathFont(.headline)
                                        Text(OathWalletConnectPolicy.safeHost(item.peer.url) ?? "—").oathFont(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                OathButton(strings.text(.scannerWCDisconnect)) { disconnectTopic = item.topic }
                                    .oathNeutralControl().disabled(service.disconnecting.contains(item.topic))
                                if service.connections.isRevoked(item.topic) {
                                    Text(strings.text(.wcDisconnectRetryDetail)).oathFont(.footnote).foregroundStyle(.secondary)
                                }
                                OathHairline()
                            }
                        }
                    }.padding(24)
                }
            }
        }
    }
    private func identity(_ peer: AppMetadata) -> OathWCIdentity {
        .init(name: peer.name, url: peer.url, icons: peer.icons, origin: nil, verification: .unknown)
    }
    private func requestTitle(_ item: OathWalletConnectService.PendingRequest) -> OathStringKey {
        switch item.payload {
        case .message(_, let signIn): signIn == nil ? .scannerWCSign : .wcSignInTitle
        case .typedData(let data): data.permission == nil ? .wcSignData : .wcApproveSignature
        case .solana(let request, _): request.message != nil ? .scannerWCSign : request.broadcasts ? .wcSubmitTransaction : .wcSignTransaction
        case .thorchain: .wcSignTransaction
        case .evm: .wcSubmitTransaction
        case .networkSwitch: .wcSwitchNetwork
        }
    }
    @ViewBuilder private func issuePage(_ issue: OathWalletConnectService.PresentationIssue) -> some View {
        if case .gas(let network, let address) = issue {
            OathWCGasPage(network: network, address: address, close: close)
        } else {
        let keys: (OathStringKey, OathStringKey) = switch issue {
        case .expired: (.wcExpiredTitle, .wcExpiredDetail)
        case .unsupported: (.wcUnsupportedTitle, .wcUnsupportedDetail)
        case .invalid: (.wcInvalidTitle, .wcInvalidDetail)
        case .disconnected: (.wcDisconnected, .wcDisconnectedDetail)
        case .unavailable: (.wcInterruptedTitle, .wcInterruptedDetail)
        case .changed: (.wcChangedTitle, .wcChangedDetail)
        case .gas: (.wcNeedGas, .wcNeedGasDetail)
        case .simulation: (.wcSimulationFailed, .wcSimulationFailedDetail)
        case .declined: (.wcRequestDeclined, .wcRequestDeclinedDetail)
        }
        OathWCStatePage(title: keys.0, detail: keys.1, symbol: keys.0 == .wcRequestDeclined ? "xmark.circle" : "exclamationmark.circle", isError: keys.0 != .wcRequestDeclined, primary: close)
        }
    }
    private func message(_ item: OathWalletConnectService.PendingRequest) -> some View {
        OathWCContent {
            OathWCDAppHeader(identity: identity(item.peer.peer))
            let network = OathImportChain.allCases.first { OathWalletConnectService.blockchain($0) == item.request.chainId }?.name ?? item.request.chainId.absoluteString
            switch item.payload {
            case .networkSwitch(let target):
                OathWCNetworkSwitchReview(current: service.connections.activeChain(item.request.topic) ?? UInt64(item.request.chainId.reference) ?? 1, requested: target)
            case .evm(let request, let quote):
                OathWCEVMReview(request: request, plan: quote.plan, close: close, approvalToken: item.approvalToken,
                    saveLimit: { try await service.reviseApproval(amount: $0) })
            case .solana(let request, let reviews):
                OathWCSolanaReview(request: request, reviews: reviews, close: close)
            case .thorchain(let request, let review):
                OathWCThorchainReview(request: request, review: review, close: close)
            case .typedData(let data):
                OathWalletConnectTypedReview(data: data, account: item.account, network: network, close: close)
            case .message(_, let signIn):
                OathWCMessageReview(message: item.display, signIn: signIn, account: item.account, network: network, close: close)
            }
            if let notice { OathSettingsFooter { Text(strings.text(notice)).foregroundStyle(.red) } }
        }.oathBottomActions {
            OathWCFooter {
                OathActionButton(title: strings.text(requestTitle(item)), isWorking: signing) { sign(nil) }
                    .disabled(signing || service.revisingTransaction).accessibilityIdentifier("walletconnect.sign")
                OathButton(strings.text(.scannerWCReject), role: .destructive) { service.declineRequest() }
                    .oathFont(.body).foregroundStyle(.red).padding(.vertical, 8).disabled(signing)
                    .accessibilityIdentifier("walletconnect.reject")
            }
        }
    }
    private var passcodePage: some View {
        OathPasscodeEntry(title: strings.text(service.pendingRequest?.isTransaction == true ? .wcSignTransaction : .scannerWCSign), filledCount: digits.count,
            isEnabled: !signing, isDeleteEnabled: !digits.isEmpty, errorMessage: notice.map(strings.text),
            titleIdentifier: "walletconnect.passcode") { key in
                guard !signing else { return }
                switch key {
                case .digit(let digit): if digits.count < 6 { digits.append(UInt8(digit)); if digits.count == 6 { sign(digits) } }
                case .delete: if !digits.isEmpty { digits.removeLast() }
                default: break
                }
            }
    }
    private func sign(_ input: [UInt8]?) {
        guard !signing else { return }; signing = true; notice = nil
        signingTask = Task {
            let network = OathImportChain.allCases.first { chain in
                service.pendingRequest.map { item in OathWalletConnectService.blockchains(networkID: chain.id).contains(item.request.chainId) } == true
            }?.id
            await OathDiagnostics.$chain.withValue(network) {
                await OathDiagnostics.$operationID.withValue(service.pendingRequest?.operationID ?? UUID()) {
                    defer { signing = false; digits = [] }
                    do {
                        try await service.sign(digits: input, reason: strings.text(service.pendingRequest?.isTransaction == true ? .wcSignTransaction : .scannerWCSign)); passcode = false
                    } catch is CancellationError { }
                    catch {
                        if let review = error as? OathWalletConnectService.ReviewFailure {
                            passcode = false; notice = review == .quoteUpdated ? .wcQuoteUpdated : .wcChangedDetail
                        }
                        else if error is OathBiometricCredentialError { passcode = true }
                        else if error as? OathWalletError == .wrongPasscode { passcode = true; notice = .unlockIncorrect }
                        else if case OathWalletError.throttled = error { notice = .unlockWait; passcode = true }
                        else if let failure = error as? SolanaSendError {
                            passcode = false
                            switch failure {
                            case .expired: service.invalidateRequest(.expired)
                            case .wrongNetwork, .wrongOwner, .malformed: service.invalidateRequest(.invalid)
                            case .insufficientFunds: notice = .wcNeedGasDetail
                            case .simulationFailed, .execution: notice = .wcSimulationFailedDetail
                            case .busy: notice = .wcTransactionBusy
                            default: notice = .sendRefreshNeeded
                            }
                            OathDiagnostics.record(error, component: "walletconnect", operation: "sign_solana", context: ["chain": "solana"])
                        }
                        else if error as? WalletConnectTypedData.Failure == .expired {
                            passcode = false; service.invalidateRequest(.expired)
                        } else if let failure = error as? WalletConnectSignIn.Failure {
                            passcode = false; service.invalidateRequest(failure == .expired ? .expired : .invalid)
                        } else {
                            OathDiagnostics.record(error, component: "walletconnect", operation: "sign_request")
                            if service.pendingRequest?.isTransaction == true {
                                passcode = false
                                switch error as? EVMSendError {
                                case .busy: notice = .wcTransactionBusy
                                case .insufficientFunds: notice = .wcNeedGasDetail
                                case .simulationFailed, .execution: notice = .wcSimulationFailedDetail
                                default: notice = .sendRefreshNeeded
                                }
                            } else { notice = .scannerWCSignatureFailed }
                        }
                    }
                }
            }
        }
    }
}
