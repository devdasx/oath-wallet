import SwiftUI
import OathDatabase
import OathDiagnostics
import OathAnkr
import OathBitcoin
@preconcurrency import WalletConnectSign

struct OathWalletConnectSheet: View {
    let uri: String?
    let session: OathWalletSession?
    let presentationID: UUID
    var onDismiss: (() -> Void)? = nil
    var onDismissDisabledChange: ((Bool) -> Void)? = nil
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
    @State private var started = false
    @State private var disconnectTopic: String?
    @State private var completionMinimumElapsedID: UUID?
    @State private var navigationPath = NavigationPath()

    private enum NavigationStep: Equatable {
        case passcode, issue, preparing, connections
        case request(UUID), proposal(String), completion(UUID)
    }
    private var navigationStep: NavigationStep {
        if passcode { return .passcode }
        if let request = service.pendingRequest { return .request(request.operationID) }
        if let proposal = service.proposal { return .proposal(proposal.value.id) }
        if let completion = service.completion { return .completion(completion.id) }
        if service.presentationIssue != nil || service.failed { return .issue }
        if service.working || service.preparingRequest { return .preparing }
        return .connections
    }

    private struct CompletionDisplay: Equatable {
        let id: UUID?
        let active: Bool
    }

    private struct CompletionObservation: Equatable {
        let sendID: String?
        let presentationID: UUID?
        let active: Bool
    }

    private var showsDeclinedRequest: Bool {
        guard !passcode, service.pendingRequest == nil, service.proposal == nil,
              service.completion == nil, case .declined? = service.presentationIssue else { return false }
        return true
    }

    private var showsConnectedResult: Bool {
        !passcode && service.pendingRequest == nil && service.proposal == nil &&
        service.completion == nil && service.presentationIssue == nil &&
        !service.working && !service.preparingRequest && !service.failed &&
        service.connectedTopic.map { topic in service.sessions.contains { $0.topic == topic } } == true
    }

    private var fitsResult: Bool {
        guard !passcode, service.pendingRequest == nil, service.proposal == nil else { return false }
        return service.completion != nil || service.presentationIssue != nil || showsConnectedResult ||
            (service.failed && !service.working && !service.preparingRequest)
    }

    private var navigationContent: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if passcode { passcodePage }
                else if let request = service.pendingRequest { message(request) }
                else if let proposal = service.proposal { proposalPage(proposal) }
                else if let completion = service.completion {
                    if completion.selectedChain != nil {
                        OathWCStatePage(title: .wcNetworkChanged, detail: .wcSwitchNetworkDetail,
                            symbol: "checkmark.circle.fill", identity: identity(completion.peer.peer), primary: close)
                    } else if let bitcoin = completion.bitcoin {
                        OathWCBitcoinCompletion(submission: bitcoin, identity: identity(completion.peer.peer), close: close)
                    } else if let xrpl = completion.xrpl {
                        OathWCXrplCompletion(submission:xrpl,identity:identity(completion.peer.peer),close:close)
                    } else if let stellar = completion.stellar {
                        OathWCStellarCompletion(submission:stellar,identity:identity(completion.peer.peer),close:close)
                    } else if let near = completion.near {
                        OathWCNearCompletion(submission:near,identity:identity(completion.peer.peer),close:close)
                    } else if let sui = completion.sui {
                        OathWCSuiCompletion(submission:sui,identity:identity(completion.peer.peer),close:close)
                    } else if let ton = completion.ton {
                        OathWCTonCompletion(submission: ton, identity: identity(completion.peer.peer), close: close)
                    } else if let solana = completion.solana {
                        OathWCSolanaCompletion(submission: solana, identity: identity(completion.peer.peer), close: close)
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
                    let failure = service.connectionFailure ?? .unknown
                    OathWCResultContent(identity: nil) {
                        OathEmptyState(title: strings.text(failure.titleKey), systemImage: failure.symbol, description: strings.text(failure.detailKey)) {
                            if let uri, !service.requiresFreshPairing { OathButton(strings.text(.tryAgain)) { Task { await service.pair(uri) } }.oathNeutralControl() }
                        }
                    }
                } else { connections }
            }
            .modifier(OathWCAdaptiveSheet(fitsResult: fitsResult))
            .background(Color(uiColor: OathSurfaceColors.canvas))
            .navigationTitle(strings.text(service.pendingRequest.map(requestTitle) ?? (service.completion == nil && service.presentationIssue == nil ? .scannerConnect : .walletConnect)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !showsDeclinedRequest && !showsConnectedResult && service.completion?.transaction == nil {
                    ToolbarItem(placement: .topBarLeading) { OathCloseButton(action: close).disabled(signing) }
                }
            }
            .oathNativeLocalization()
        }
    }

    var body: some View {
        // Review, authorization and receipts share one navigation/presentation
        // lifetime. Only the content and the native detent change.
        navigationContent
        .preferredColorScheme(nil).oathLanguage(strings.language)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: OathSurfaceColors.canvas))
        .interactiveDismissDisabled(signing || service.proposal != nil || service.pendingRequest != nil)
        .onChange(of: signing || service.proposal != nil || service.pendingRequest != nil, initial: true) { _, disabled in
            onDismissDisabledChange?(disabled)
        }
        .alert(strings.text(.scannerWCDisconnect), isPresented: Binding(
            get: { disconnectTopic != nil }, set: { if !$0 { disconnectTopic = nil } }
        ), presenting: disconnectTopic) { topic in
            OathButton(strings.text(.scannerWCDisconnect), role: .destructive) {
                Task { _ = await service.disconnect(topic) }
            }.accessibilityIdentifier("walletconnect.disconnect.confirm")
            OathButton(strings.text(.cancel), role: .cancel) { }
        } message: { _ in Text(strings.text(.wcDisconnectDetail)) }

        .task(id: CompletionDisplay(id: service.completion?.id, active: scenePhase == .active)) {
            completionMinimumElapsedID = nil
            guard scenePhase == .active, let id = service.completion?.id else { return }
            do { try await Task.sleep(for: OathWalletConnectPolicy.CompletionHandoff.minimumDisplay) }
            catch { return } // Dismissal/background cancels the display timer, not an app failure.
            guard !Task.isCancelled, service.completion?.id == id else { return }
            completionMinimumElapsedID = id
            handoffCompletionIfReady()
        }
        .onChange(of: service.completionHandoffRequested) { _, _ in handoffCompletionIfReady() }
        .onChange(of: signing) { _, active in if !active { handoffCompletionIfReady() } }
        .task(id: CompletionObservation(sendID: service.completion?.transaction?.sendID,
                                       presentationID: presentationID, active: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            await service.trackTransactionCompletion(presentationID: presentationID)
        }
        .task {
            guard !started, service.presentationDidOpen(presentationID) else { return }
            started = true
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
        .onChange(of: session?.isUnlocked) { _, unlocked in if unlocked == false { signingTask?.cancel(); digits = []; passcode = false; dismissSheet() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { signingTask?.cancel(); digits = [] } }
        .onChange(of: service.pendingRequest?.id) { _, _ in notice = nil; passcode = false; digits = [] }
        .onChange(of: navigationStep) { _, _ in
            // Expiry or a new request must not leave a previous request's
            // details on top. Preserve the stack itself and its sheet owner.
            if !navigationPath.isEmpty { navigationPath = NavigationPath() }
        }
        .onDisappear {
            signingTask?.cancel(); digits = []
            // A full-screen address/browser page can cover this sheet. Only
            // its presenter's actual dismissal ends the request ownership.
        }
    }
    private func updateSelection() {
        guard let proposal = service.proposal else { selected = []; return }
        let available = Set(accounts.flatMap { OathWalletConnectService.blockchains(networkID: $0.networkID).map(\.absoluteString) })
        selected = (OathWalletConnectService.requested(proposal.value, required: true)
            .union(OathWalletConnectService.requested(proposal.value, required: false))).intersection(available)
    }
    private func proposalPage(_ proposal: OathWalletConnectService.Proposal) -> some View {
        // Namespace compatibility is form validation; retain its reason without logging each render.
        let negotiation = Result { try service.namespaces(for: proposal.value, accounts: accounts, selected: selected) }
        let negotiated = try? negotiation.get()
        let negotiationFailure: OathWalletConnectPolicy.ConnectionFailure?
        if case .failure(let error) = negotiation { negotiationFailure = .classify(error) }
        else { negotiationFailure = nil }
        let required = OathWalletConnectService.requested(proposal.value, required: true)
        let requested = required.union(OathWalletConnectService.requested(proposal.value, required: false))
        // Keep the original proposal intact for required-namespace validation;
        // the list only presents networks this wallet can actually share.
        let networks = OathWalletConnectPolicy.networkGroups(requested: requested, required: required).compactMap { group -> OathWCNetworkChoice? in
            let solana = SolanaSendNetwork(walletConnectChain: group.id)
            guard let chain = OathWalletConnectService.chain(for: group.id),
                  let account = accounts.first(where: { $0.networkID == chain.id }) else { return nil }
            return .init(selection: group, name: NearSendNetwork(walletConnectChain:group.id)?.walletConnectName ?? SuiSendNetwork(walletConnectChain:group.id)?.walletConnectName ?? PolkadotConnectNetwork(chain: group.id)?.name ?? BitcoinConnectNetwork(chain: group.id)?.name ?? TronSendNetwork(walletConnectChain: group.id)?.walletConnectName ?? TonSendNetwork(walletConnectChain: group.id)?.walletConnectName ?? solana?.walletConnectName ?? chain.name, logo: "network-" + chain.id,
                address: account.address)
        }
        let methods = (negotiated ?? [:]).keys.sorted().map { key in
            OathWCMethodGroup(id: key, methods: negotiated?[key]?.methods.sorted() ?? [], events: negotiated?[key]?.events.sorted() ?? [])
        }
        let identity = OathWCIdentity(name: proposal.value.proposer.name, url: proposal.value.proposer.url,
            icons: proposal.value.proposer.icons, origin: proposal.verify?.origin,
            verification: proposal.blocked ? .blocked : proposal.unverified ? .unknown : .matched)
        return OathWalletConnectConsent(identity: identity,
            wallets: session?.wallets.map { .init(id: $0.id, name: session?.walletName($0, strings: strings) ?? "", colorHex: $0.colorHex) } ?? [],
            networks: networks, methods: methods, supported: negotiated != nil, loadingAccounts: loadingAccounts,
            working: service.working, failed: service.failed, walletID: walletID, selected: $selected,
            acknowledged: $acknowledged, approve: {
                sign(nil)
            }, reject: close, close: close,
            connectionFailure: service.connectionFailure, compatibilityFailure: negotiationFailure,
            unavailableMethods: Set(proposal.value.requiredNamespaces.values.flatMap(\.methods)),
            includesSignIn: proposal.value.requests?.authentication?.isEmpty == false)
    }
    private func dismissSheet() {
        service.presentationWillDismiss(presentationID)
        if let onDismiss { onDismiss() } else { dismiss() }
    }
    private func close() {
        guard !signing else { return }
        if service.proposal != nil { onProposalRejected?() }
        signingTask?.cancel(); service.rejectRequest(); Task { await service.reject(presentationID: presentationID) }; dismissSheet()
    }
    private func handoffCompletionIfReady() {
        guard scenePhase == .active, !signing, let id = completionMinimumElapsedID else { return }
        service.handoffCompletion(id, presentationID: presentationID)
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
                                OathButton(strings.text(.scannerWCDisconnect), role: .destructive) { disconnectTopic = item.topic }
                                    .foregroundStyle(.red).tint(.red).disabled(service.disconnecting.contains(item.topic))
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
        if item.thorchainSwap != nil { return .wcConfirmSwap }
        return switch item.payload {
        case .message(_, let signIn): signIn == nil ? .scannerWCSign : .wcSignInTitle
        case .typedData(let data): data.permission == nil ? .wcSignData : .wcApproveSignature
        case .bitcoin(let request, _, _): request.method == "signMessage" ? .scannerWCSign : request.broadcasts ? .wcSubmitTransaction : .wcSignTransaction
        case .xrpl(let request, _): request.broadcasts ? .wcSubmitTransaction : .wcSignTransaction
        case .stellar(let request, _): request.broadcasts ? .wcSubmitTransaction : .wcSignTransaction
        case .near: .wcSignTransaction
        case .nearAccess: .wcSubmitTransaction
        case .sui(let request, _): request.message != nil ? .scannerWCSign : request.broadcasts ? .wcSubmitTransaction : .wcSignTransaction
        case .polkadot(let request, _): request.message == nil ? .wcSignTransaction : .scannerWCSign
        case .tron(let request, _): request.message == nil ? .wcSignTransaction : .scannerWCSign
        case .ton(let request, _): request.broadcasts ? .wcSubmitTransaction : .wcSignData
        case .solana(let request, _): request.message != nil ? .scannerWCSign : request.broadcasts ? .wcSubmitTransaction : .wcSignTransaction
        case .thorchain(_, let review): review.swap == nil ? .wcSignTransaction : .wcConfirmSwap
        case .evm(let request, _): OathWCEVMReview.isAccessReview(request) ? .wcReviewApproval : .wcSubmitTransaction
        case .networkSwitch: .wcSwitchNetwork
        }
    }
    @ViewBuilder private func issuePage(_ issue: OathWalletConnectService.PresentationIssue) -> some View {
        if case .gas(let network, let address) = issue {
            OathWCGasPage(network: network, address: address, close: close)
        } else if case .declined = issue {
            OathWCDeclinedPage(close: close)
        } else {
        let keys: (OathStringKey, OathStringKey) = switch issue {
        case .expired: (.wcExpiredTitle, .wcExpiredDetail)
        case .unsupported: (.wcUnsupportedTitle, .wcUnsupportedDetail)
        case .invalid: (.wcInvalidTitle, .wcInvalidDetail)
        case .disconnected: (.wcDisconnected, .wcDisconnectedDetail)
        case .unavailable: (.wcInterruptedTitle, .wcInterruptedDetail)
        case .changed: (.wcChangedTitle, .wcChangedDetail)
        case .gas: (.wcNeedGas, .wcNeedGasDetail)
        case .bitcoinFunds: (.sendInsufficient, .sendFeeNotIncluded)
        case .simulation: (.wcSimulationFailed, .wcSimulationFailedDetail)
        case .declined: (.wcRequestDeclined, .wcRequestDeclinedDetail)
        }
        OathWCStatePage(title: keys.0, detail: keys.1, symbol: keys.0 == .wcRequestDeclined ? "xmark.circle" : "exclamationmark.circle", isError: keys.0 != .wcRequestDeclined, primary: close)
        }
    }
    private func message(_ item: OathWalletConnectService.PendingRequest) -> some View {
        OathWCContent {
            if requestTitle(item) != .wcReviewApproval && requestTitle(item) != .wcConfirmSwap && requestTitle(item) != .wcApproveSignature {
                OathWCDAppHeader(identity: identity(item.peer.peer))
            }
            let network = OathWalletConnectService.chain(for: item.request.chainId.absoluteString)?.name ?? item.request.chainId.absoluteString
            switch item.payload {
            case .networkSwitch(let target):
                OathWCNetworkSwitchReview(current: service.connections.activeChain(item.request.topic) ?? UInt64(item.request.chainId.reference) ?? 1, requested: target)
            case .evm(let request, let quote):
                if let swap = item.thorchainSwap {
                    OathWCThorchainSwapReview(inputAsset: swap.inputAsset, inputAmount: swap.deposit.amount,
                        inputDecimals: swap.decimals, sender: request.sender, quote: swap.quote,
                        gasAmount: OathSendAmount.units(String(quote.plan.fee), decimals: 18) ?? "—", gasSymbol: quote.plan.network.symbol,
                        currency: session?.portfolio?.currency ?? "USD", exchangeRate: session?.portfolio?.displayExchangeRate)
                } else {
                    OathWCEVMReview(request: request, plan: quote.plan, close: close, approvalToken: item.approvalToken,
                        saveLimit: { try await service.reviseApproval(amount: $0) },
                        walletName: requestWalletName(item), tokenSymbol: requestTokenSymbol(item, request: request))
                }
            case .bitcoin(let request, let plan, _):
                OathWCBitcoinReview(request: request, plan: plan)
            case .xrpl(let request, let review):
                OathWCXrplReview(request:request,review:review)
            case .stellar(let request, let review):
                OathWCStellarReview(request:request,review:review)
            case .nearAccess(_, let review):
                OathWCNearReview(request:review.request,review:review)
            case .near(let request, let review):
                OathWCNearReview(request:request,review:review)
            case .sui(let request, let review):
                OathWCSuiReview(request:request,review:review,close:close)
            case .polkadot(let request, let review):
                OathWCPolkadotReview(request:request, review:review, close:close)
            case .tron(let request, let review):
                OathWCTronReview(request:request, review:review, close:close)
            case .ton(let request, let plan):
                OathWCTonReview(request: request, plan: plan)
            case .solana(let request, let reviews):
                OathWCSolanaReview(request: request, reviews: reviews, close: close)
            case .thorchain(let request, let review):
                if let swap = review.swap, let asset = ThorchainSwapAsset("THOR.RUNE") {
                    OathWCThorchainSwapReview(inputAsset: asset, inputAmount: swap.input, inputDecimals: 8,
                        sender: request.sender, quote: swap, gasAmount: OathSendAmount.units(String(review.fee), decimals: 8) ?? "—", gasSymbol: "RUNE",
                        currency: session?.portfolio?.currency ?? "USD", exchangeRate: session?.portfolio?.displayExchangeRate)
                } else { OathWCThorchainReview(request: request, review: review, close: close) }
            case .typedData(let data):
                OathWalletConnectTypedReview(data: data, account: item.account, network: network, close: close)
            case .message(_, let signIn):
                OathWCMessageReview(message: item.display, signIn: signIn, account: item.account, network: network, close: close)
            }
            if let notice { OathSettingsFooter { Text(strings.text(notice)).foregroundStyle(.red) } }
        }.oathBottomActions {
            VStack(spacing: OathActionMetrics.spacing) {
                if requestTitle(item) == .wcReviewApproval { OathWCAccessFooterNotice() }
                OathBottomAction(title: strings.text(requestTitle(item)), identifier: "walletconnect.sign",
                                 isEnabled: !signing && !service.revisingTransaction, isWorking: signing) { sign(nil) }
                OathBottomAction(title: strings.text(.scannerWCReject), identifier: "walletconnect.reject",
                                 role: .destructive, appearance: .destructiveSecondary, isEnabled: !signing) {
                    service.declineRequest()
                }
            }
        }
    }
    private func requestWalletName(_ item: OathWalletConnectService.PendingRequest) -> String {
        guard let session, let wallet = session.wallets.first(where: { $0.id == item.walletID }) else {
            return strings.text(.wcWalletUnavailable)
        }
        return session.walletName(wallet, strings: strings)
    }
    private func requestTokenSymbol(_ item: OathWalletConnectService.PendingRequest, request: WalletConnectEVMRequest) -> String? {
        guard let snapshot = session?.portfolio, snapshot.wallet.id == item.walletID,
              let network = EVMSendNetwork.allCases.first(where: { $0.chainID == request.chainID }) else { return nil }
        return snapshot.holdings.first {
            $0.networkID == network.rawValue && $0.reference.lowercased() == request.recipient.lowercased()
        }?.symbol
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
                        if service.proposal != nil {
                            try await service.approve(accounts: accounts, selected: selected, walletID: walletID, acknowledged: acknowledged, digits: input, reason: strings.text(.wcSignInTitle))
                        } else { try await service.sign(digits: input, reason: strings.text(service.pendingRequest?.isTransaction == true ? .wcSignTransaction : .scannerWCSign)) }; passcode = false
                    } catch is CancellationError { }
                    catch {
                        if let review = error as? OathWalletConnectService.ReviewFailure {
                            passcode = false; notice = review == .quoteUpdated ? .wcQuoteUpdated : .wcChangedDetail
                        }
                        else if error is OathBiometricCredentialError { passcode = true }
                        else if error as? OathWalletError == .wrongPasscode { passcode = true; notice = .unlockIncorrect }
                        else if case OathWalletError.throttled = error { notice = .unlockWait; passcode = true }
                        else if error is SendFeeFundingError {
                            passcode = false; notice = .wcNeedGasDetail
                            OathDiagnostics.record(error, component:"walletconnect", operation:"sign_fee")
                        }
                        else if let failure = error as? BitcoinConnectError {
                            passcode = false
                            switch failure {
                            case .expired: service.invalidateRequest(.expired)
                            case .unsupported: service.invalidateRequest(.unsupported)
                            case .wrongAccount, .invalidRequest, .invalidPSBT, .wrongInput: service.invalidateRequest(.invalid)
                            case .insufficientFunds: notice = .sendInsufficient
                            case .busy: notice = .wcTransactionBusy
                            default: notice = .sendRefreshNeeded
                            }
                            OathDiagnostics.record(error,component:"walletconnect",operation:"sign_bitcoin",context:["chain":"bitcoin"])
                        }
                        else if let failure = error as? XrplSendError {
                            passcode = false
                            switch failure {
                            case .expired: service.invalidateRequest(.expired)
                            case .wrongNetwork, .wrongOwner, .malformed: service.invalidateRequest(.invalid)
                            case .insufficientFunds, .reserve: notice = .sendInsufficient
                            case .simulation: notice = .wcSimulationFailedDetail
                            case .busy: notice = .wcTransactionBusy
                            default: notice = .sendRefreshNeeded
                            }
                            OathDiagnostics.record(error,component:"walletconnect",operation:"sign_xrpl",context:["chain":"xrpl"])
                        }
                        else if let failure = error as? StellarSendError {
                            passcode = false
                            switch failure {
                            case .expired: service.invalidateRequest(.expired)
                            case .wrongNetwork, .wrongOwner, .malformed: service.invalidateRequest(.invalid)
                            case .insufficientFunds, .reserve: notice = .sendInsufficient
                            case .simulation: notice = .wcSimulationFailedDetail
                            case .busy: notice = .wcTransactionBusy
                            default: notice = .sendRefreshNeeded
                            }
                            OathDiagnostics.record(error,component:"walletconnect",operation:"sign_stellar",context:["chain":"stellar"])
                        }
                        else if let failure = error as? NearSendError {
                            passcode = false
                            switch failure {
                            case .expired: service.invalidateRequest(.expired)
                            case .unsupportedAccount: service.invalidateRequest(.unsupported)
                            case .wrongNetwork, .wrongOwner, .malformed: service.invalidateRequest(.invalid)
                            case .insufficientFunds, .storageFunds: notice = .sendInsufficient
                            case .busy: notice = .wcTransactionBusy
                            default: notice = .sendRefreshNeeded
                            }
                            OathDiagnostics.record(error,component:"walletconnect",operation:"sign_near",context:["chain":"near"])
                        }
                        else if let failure = error as? SuiSendError {
                            passcode = false
                            switch failure {
                            case .expired: service.invalidateRequest(.expired)
                            case .wrongNetwork, .wrongOwner, .malformed: service.invalidateRequest(.invalid)
                            case .insufficientFunds: notice = .sendInsufficient
                            case .insufficientGas: notice = .wcNeedGasDetail
                            case .simulationFailed: notice = .wcSimulationFailedDetail
                            case .busy: notice = .wcTransactionBusy
                            default: notice = .sendRefreshNeeded
                            }
                            OathDiagnostics.record(error,component:"walletconnect",operation:"sign_sui",context:["chain":"sui"])
                        }
                        else if let failure = error as? PolkadotSendError {
                            passcode = false
                            switch failure {
                            case .expired: service.invalidateRequest(.expired)
                            case .runtimeUnsupported: service.invalidateRequest(.unsupported)
                            case .wrongNetwork, .wrongOwner, .malformed: service.invalidateRequest(.invalid)
                            case .insufficientFunds: notice = .sendInsufficient
                            default: notice = .sendRefreshNeeded
                            }
                            OathDiagnostics.record(error, component:"walletconnect", operation:"sign_polkadot", context:["chain":"polkadot"])
                        }
                        else if let failure = error as? TronSendError {
                            passcode = false
                            switch failure {
                            case .expired: service.invalidateRequest(.expired)
                            case .wrongNetwork, .wrongOwner, .malformed, .changed: service.invalidateRequest(.invalid)
                            case .unsupportedAccount: service.invalidateRequest(.unsupported)
                            case .insufficientFunds: notice = .wcNeedGasDetail
                            case .simulation, .execution: notice = .wcSimulationFailedDetail
                            default: notice = .sendRefreshNeeded
                            }
                            OathDiagnostics.record(error, component:"walletconnect", operation:"sign_tron", context:["chain":"tron"])
                        }
                        else if let failure = error as? TonSendError {
                            passcode = false
                            switch failure {
                            case .expired: service.invalidateRequest(.expired)
                            case .wrongNetwork, .wrongOwner, .malformed: service.invalidateRequest(.invalid)
                            case .insufficientFunds: notice = .wcNeedGasDetail
                            case .simulationFailed, .execution: notice = .wcSimulationFailedDetail
                            case .busy: notice = .wcTransactionBusy
                            default: notice = .sendRefreshNeeded
                            }
                            OathDiagnostics.record(error, component: "walletconnect", operation: "sign_ton", context: ["chain": "ton"])
                        }
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
