import SwiftUI
import OathAnkr
import OathDiagnostics

struct OathWCEVMReview: View {
    let request: WalletConnectEVMRequest
    let plan: EVMSendPlan
    let close: @MainActor () -> Void
    var approvalToken: WalletConnectApprovalToken? = nil
    var saveLimit: (@MainActor (String) async throws -> Void)? = nil
    @Environment(\.oathLocalizer) private var strings
    @State private var identities: [String: ContractIdentity] = [:]
    private var action: WalletConnectEVMAction { .init(request) }
    private var swap: WalletConnectSwapReview { .init(request) }
    static func title(_ action: WalletConnectEVMAction) -> OathStringKey {
        switch action.kind {
        case .approval, .operatorApproval: .wcReviewApproval
        case .swap: .wcReviewSwap
        case .nft: .wcReviewNFT
        case .transfer: .wcReviewTransaction
        case .contract: .wcContractCall
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                OathWCNetworkBadge(chainID: request.chainID)
                Text(strings.text(swap.routes.isEmpty ? Self.title(action) : .wcReviewSwap)).oathFont(.title2, weight: .semibold)
                if let approvalToken, let amount = action.fields.first(where: { $0.label == .amount })?.value {
                    Text(action.isUnlimited ? strings.text(.permissionUnlimited) : OathSendAmount.units(amount, decimals: approvalToken.decimals) ?? amount)
                        .oathFont(.largeTitle, weight: .semibold).minimumScaleFactor(0.6).lineLimit(2)
                        .environment(\.layoutDirection, .leftToRight)
                    Text(strings.text(.wcConfirmedLimit)).oathFont(.subheadline).foregroundStyle(.secondary)
                }
                if (request.value != "0" && !swap.routes.contains { $0.input.reference == "native" }) || request.call.bytes.isEmpty {
                    Text((OathSendAmount.units(request.value, decimals: 18) ?? request.value) + " " + plan.network.symbol)
                        .oathFont(.largeTitle, weight: .semibold).minimumScaleFactor(0.6).lineLimit(2)
                        .environment(\.layoutDirection, .leftToRight)
                    Text(strings.text(.wcCallValue)).oathFont(.subheadline).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(24)
            if !swap.routes.isEmpty {
                OathWCSwapSummary(request: request, review: swap, identities: identities)
            } else if swap.incomplete {
                OathSettingsFooter { Text(strings.text(.wcDecodedUnavailable)) }
            }
            OathWCValue(title: strings.text(.scannerWCAccount), value: request.sender, leftToRight: true)
            OathWCValue(title: strings.text(.tokenNetwork), value: OathImportChain(rawValue: plan.network.rawValue)?.name ?? plan.network.rawValue, leftToRight: true)
            NavigationLink {
                OathWCAddressDetails(address: request.recipient, title: request.call.bytes.isEmpty ? .sendRecipient : .wcContractAddress, close: close)
            } label: {
                OathSettingsRow(title: strings.text(request.call.bytes.isEmpty ? .sendRecipient : .wcContractAddress),
                    value: request.recipient, accessory: .disclosure)
            }.buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.transaction.recipient")
            if action.kind == .approval || action.kind == .operatorApproval {
                OathSettingsFooter { Text(strings.text(action.kind == .operatorApproval ? .wcOperatorDetail : approvalToken == nil ? .wcAmbiguousApproval : .wcApprovalCallDetail)) }
            }
            ForEach(Array((swap.routes.isEmpty ? action.fields : []).enumerated()), id: \.offset) { _, field in
                if field.label == .amount, approvalToken != nil { EmptyView() }
                else { OathWCValue(title: strings.text(field.label == .amount && action.kind == .approval && approvalToken == nil ? .wcApprovalRawValue : Self.label(field.label)), value: field.label == .access
                    ? strings.text(field.value == "1" ? .permissionAllItems : .permissionNone) : field.value, leftToRight: field.label != .access)
                }
            }
            if action.kind == .approval {
                NavigationLink {
                    if let approvalToken, let saveLimit {
                        OathWCApprovalLimit(token: approvalToken, amount: action.fields.first { $0.label == .amount }?.value ?? "0", save: saveLimit)
                    } else { OathWCContent {
                        OathWCValue(title: strings.text(.wcConfirmedLimit), value: action.fields.first { $0.label == .amount }?.value ?? "—", leftToRight: true)
                        OathSettingsFooter { Text(strings.text(approvalToken == nil ? .wcAmbiguousApproval : action.isUnlimited ? .wcUnlimitedDetail : .wcApprovalCallDetail)) }
                    }.navigationTitle(strings.text(.wcConfirmedLimit)).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }
                    }
                } label: { OathSettingsRow(title: strings.text(.wcConfirmedLimit), icon: "slider.horizontal.3") }
                    .buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.transaction.limit")
            }
            if !swap.routes.isEmpty {
                NavigationLink {
                    OathWCCallDetails(request: request, close: close, approvalToken: approvalToken, initialIdentities: identities)
                } label: { OathSettingsRow(title: strings.text(.wcSwapDetails), icon: "arrow.triangle.swap") }
                    .buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.transaction.swapDetails")
                OathSettingsFooter { Text(strings.text(.wcSwapCallDetail)) }
            }
            OathSettingsSectionRule()
            NavigationLink {
                OathWCEVMFees(plan: plan, close: close)
            } label: {
                OathSettingsRow(title: strings.text(.wcMaximumFee), value: fee)
            }.buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.transaction.fees")
            NavigationLink {
                OathWCCallDetails(request: request, close: close, approvalToken: approvalToken, initialIdentities: identities)
            } label: { OathSettingsRow(title: strings.text(.wcTransactionData), icon: "text.alignleft") }
                .buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.transaction.data")
            if !request.call.bytes.isEmpty { OathSettingsFooter { Text(strings.text(.wcCallWarning)) } }
        }
        .task(id: OathWCCallMetadata.Key(request)) {
            identities = [:]
            await OathWCCallMetadata.load(request: request, approvalToken: approvalToken) { identity in
                identities[identity.address] = identity
            }
        }
    }
    private var fee: String { (OathSendAmount.units(String(plan.fee), decimals: 18) ?? "—") + " " + plan.network.symbol }
    static func label(_ field: WalletConnectEVMAction.Label) -> OathStringKey {
        switch field {
        case .recipient: .sendRecipient
        case .owner: .scannerWCAccount
        case .spender: .wcSpender
        case .amount: .wcRawAmount
        case .tokenID: .wcTokenID
        case .access: .wcReviewPermissions
        case .tokenIn: .wcTokenIn
        case .tokenOut: .wcTokenOut
        case .minimumReceived: .wcMinimumOut
        case .maximumSpent: .historyMaximum
        case .poolFee: .wcPoolFee
        case .deadline: .wcSignatureDeadline
        case .priceLimit: .wcPriceLimit
        }
    }
}

struct OathWCAddressDetails: View {
    let address: String
    let title: OathStringKey
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathWCContent {
            OathWCValue(title: strings.text(title), value: address, leftToRight: true)
        }.navigationTitle(strings.text(title)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }
    }
}

struct OathWCEVMFees: View {
    let plan: EVMSendPlan
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathWCContent { fields }
            .navigationTitle(strings.text(.wcFeeDetails)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }
    }
    var fields: some View {
        VStack(spacing: 0) {
            OathWCValue(title: strings.text(.wcMaximumFee), value: (OathSendAmount.units(String(plan.fee), decimals: 18) ?? "—") + " " + plan.network.symbol, leftToRight: true)
            OathWCValue(title: strings.text(.wcGasLimit), value: String(plan.gasLimit), leftToRight: true)
            OathWCValue(title: strings.text(.wcGasPrice), value: String(plan.maxFeePerGas) + " wei", leftToRight: true)
            if !plan.legacy { OathWCValue(title: strings.text(.wcPriorityFee), value: String(plan.maxPriorityFeePerGas) + " wei", leftToRight: true) }
            if plan.extraFee > 0 { OathWCValue(title: strings.text(.wcRollupFee), value: (OathSendAmount.units(String(plan.extraFee), decimals: 18) ?? "—") + " " + plan.network.symbol, leftToRight: true) }
            OathWCValue(title: strings.text(.wcNonce), value: String(plan.nonce), leftToRight: true)
            OathSettingsFooter { Text(strings.text(.wcFeeDetail)) }
        }
    }
}

struct OathWCEVMCompletion: View {
    let transaction: OathWalletConnectService.TransactionCompletion
    let identity: OathWCIdentity
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    private var confirmed: Bool { transaction.progress.outcome == .confirmed }
    private var failed: Bool { transaction.progress.outcome == .failed }
    private var isApproval: Bool { transaction.action?.kind == .approval || transaction.action?.kind == .operatorApproval }
    private var title: OathStringKey {
        if transaction.progress.outcome == .cancelled { return .wcTransactionCancelled }
        if transaction.progress.outcome == .replaced { return .wcTransactionReplaced }
        if failed { return .wcTransactionFailed }
        if isApproval { return confirmed ? .wcApprovalConfirmed : .wcApprovalPending }
        return confirmed ? .wcTransactionConfirmed : .wcTransactionPending
    }
    private var detail: OathStringKey {
        if transaction.progress.outcome == .cancelled { return .wcTransactionCancelledDetail }
        if transaction.progress.outcome == .replaced { return .wcTransactionReplacedDetail }
        if failed { return .wcTransactionFailedDetail }
        if isApproval { return confirmed ? .wcApprovalConfirmedDetail : .wcApprovalPendingDetail }
        return confirmed ? .wcTransactionConfirmedDetail : .wcTransactionPendingDetail
    }
    private var symbol: String {
        switch transaction.progress.outcome {
        case .confirmed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        case .replaced: "arrow.triangle.2.circlepath"
        case .pending: "clock"
        }
    }
    var body: some View {
        OathWCContent {
            VStack(spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 56)).foregroundStyle(failed ? Color.red : OathOnboardingColors.blue)
                Text(strings.text(title))
                    .oathFont(.title2, weight: .semibold)
                    .accessibilityIdentifier("walletconnect.transaction.status")
                Text(strings.text(detail))
                    .oathFont(.body).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).padding(24).padding(.top, 20)
            OathWCDAppHeader(identity: identity)
            if isApproval, let action = transaction.action {
                if let spender = action.fields.first(where: { $0.label == .spender })?.value {
                    OathWCValue(title: strings.text(.wcSpender), value: spender, leftToRight: true)
                }
                if let amount = action.fields.first(where: { $0.label == .amount })?.value {
                    OathWCValue(title: strings.text(transaction.approvalToken == nil ? .wcApprovalRawValue : .wcConfirmedLimit),
                        value: action.isUnlimited ? strings.text(.permissionUnlimited) : transaction.approvalToken.flatMap { OathSendAmount.units(amount, decimals: $0.decimals) } ?? amount,
                        leftToRight: true)
                }
                if let access = action.fields.first(where: { $0.label == .access })?.value {
                    OathWCValue(title: strings.text(.wcReviewPermissions), value: strings.text(access == "1" ? .permissionAllItems : .permissionNone))
                }
            }
            OathWCValue(title: strings.text(.assetTransactionID), value: transaction.hash, leftToRight: true)
            NavigationLink {
                OathWCContent {
                    OathWCValue(title: strings.text(.assetTransactionID), value: transaction.hash, leftToRight: true)
                    OathWCValue(title: strings.text(.transactionStatus), value: strings.text(title))
                    if let replacement = transaction.progress.snapshot?.replacementHash {
                        OathWCValue(title: strings.text(.transactionReplacement), value: replacement, leftToRight: true)
                    }
                    OathWCValue(title: strings.text(.scannerWCAccount), value: transaction.plan.sender, leftToRight: true)
                    OathWCValue(title: strings.text(.sendRecipient), value: transaction.plan.recipient, leftToRight: true)
                    if let actualFee = transaction.actualFee {
                        OathWCValue(title: strings.text(.transactionNetworkFee), value: (OathSendAmount.units(actualFee, decimals: 18) ?? actualFee) + " " + transaction.plan.network.symbol, leftToRight: true)
                    }
                    OathWCEVMFees(plan: transaction.plan, close: close).fields
                }.navigationTitle(strings.text(.assetTransaction)).navigationBarTitleDisplayMode(.inline)
            } label: { OathSettingsRow(title: strings.text(.assetTransaction), icon: "doc.text.magnifyingglass") }
                .buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.transaction.details")
        }.oathBottomActions {
            OathWCFooter { OathActionButton(title: strings.text(.done), action: close) }
        }
    }
}

struct OathWCGasPage: View {
    let network: String
    let address: String
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathWCContent {
            VStack(spacing: 18) {
                Image(systemName: "fuelpump").font(.system(size: 52)).foregroundStyle(.red)
                Text(strings.text(.wcNeedGas)).oathFont(.title2, weight: .semibold)
                Text(strings.text(.wcNeedGasDetail)).oathFont(.body).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).padding(24)
            OathWCValue(title: strings.text(.tokenNetwork), value: OathImportChain(rawValue: network)?.name ?? network, leftToRight: true)
            NavigationLink {
                OathWCReceiveGas(network: network, address: address, close: close)
            } label: { OathSettingsRow(title: strings.text(.receive), icon: "arrow.down.left") }
                .buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.gas.receive")
        }.oathBottomActions {
            OathWCFooter { OathActionButton(title: strings.text(.done), action: close) }
        }
    }
}

private struct OathWCReceiveGas: View {
    let network: String
    let address: String
    let close: @MainActor () -> Void
    @State private var image: CGImage?
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathWCContent {
            OathWCValue(title: strings.text(.tokenNetwork), value: OathImportChain(rawValue: network)?.name ?? network, leftToRight: true)
            if let image {
                ZStack {
                    Image(decorative: image, scale: 1).resizable().interpolation(.none)
                    OathNetworkLogo(asset: "network-" + network, size: OathReceiveQRCode.displaySide * OathReceiveQRCode.logoFraction)
                }.frame(width: OathReceiveQRCode.displaySide, height: OathReceiveQRCode.displaySide)
                    .padding(24).frame(maxWidth: .infinity)
            }
            OathWCValue(title: strings.text(.scannerWCAccount), value: address, leftToRight: true)
            OathSettingsFooter { Text(strings.text(.wcNeedGasDetail)) }
        }.navigationTitle(strings.text(.receive)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }
            .oathBottomActions {
                OathWCFooter { OathActionButton(title: strings.text(.copyAddress)) { OathClipboard.copy(address) } }
            }.task(id: address) {
                let address = address
                let rendered = await Task.detached(priority: .userInitiated) { OathReceiveQRCode.image(for: address) }.value
                guard !Task.isCancelled else { return }
                if let rendered { image = rendered }
                else { OathDiagnostics.record(DiagnosticFailure("QR rendering failed"), component: "walletconnect", operation: "receive_qr") }
            }
    }
}

struct OathWCApprovalLimit: View {
    let token: WalletConnectApprovalToken
    let amount: String
    let save: @MainActor (String) async throws -> Void
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var unlimited = false
    @State private var working = false
    @State private var failed = false
    @State private var saveTask: Task<Void, Never>?
    private var atomic: String? {
        if unlimited { return WalletConnectEVMAction.maximum }
        guard let normalized = OathSendAmount.normalized(input, locale: strings.language.locale) else { return nil }
        if normalized == "0" { return "0" }
        guard let value = try? OathSendAmount.atomic(input, decimals: token.decimals, locale: strings.language.locale) else { return nil }
        return try? EVMSendAmount.checked(value)
    }
    var body: some View {
        OathWCContent {
            OathWCValue(title: strings.text(.wcTokenContract), value: token.contract, leftToRight: true)
            TextField(strings.text(.wcConfirmedLimit), text: $input)
                .keyboardType(.decimalPad).oathFont(.largeTitle, weight: .semibold)
                .multilineTextAlignment(.center).padding(24).disabled(unlimited || working)
                .accessibilityIdentifier("walletconnect.limit.input")
            Toggle(strings.text(.permissionUnlimited), isOn: $unlimited)
                .oathFont(.body).padding(20).disabled(working)
                .accessibilityIdentifier("walletconnect.limit.unlimited")
            OathSettingsFooter { Text(strings.text(unlimited ? .wcUnlimitedDetail : .wcEditableApprovalDetail)) }
            OathWCValue(title: strings.text(.wcTokenBalance), value: OathSendAmount.units(token.balance, decimals: token.decimals) ?? token.balance, leftToRight: true)
            if failed { OathSettingsFooter { Text(strings.text(.wcLimitFailed)).foregroundStyle(.red) } }
        }
        .navigationTitle(strings.text(.wcConfirmedLimit)).navigationBarTitleDisplayMode(.inline)
        .oathBottomActions {
            OathWCFooter {
                OathActionButton(title: strings.text(.save), isWorking: working) {
                    guard let atomic, !working else { return }
                    working = true; failed = false
                    saveTask = Task { @MainActor in
                        defer { working = false }
                        do { try await save(atomic); try Task.checkCancellation(); dismiss() }
                        catch is CancellationError { }
                        catch {
                            OathDiagnostics.record(error, component: "walletconnect", operation: "revise_approval")
                            failed = true
                        }
                    }
                }.disabled(atomic == nil || working).accessibilityIdentifier("walletconnect.limit.save")
            }
        }.onAppear {
            unlimited = amount == WalletConnectEVMAction.maximum
            input = OathSendAmount.units(unlimited ? "0" : amount, decimals: token.decimals) ?? "0"
        }.onDisappear { saveTask?.cancel() }
    }
}
