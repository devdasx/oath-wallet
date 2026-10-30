import SwiftUI
import OathAnkr
import OathDiagnostics

struct OathWCEVMReview: View {
    let request: WalletConnectEVMRequest
    let plan: EVMSendPlan
    let close: @MainActor () -> Void
    var approvalToken: WalletConnectApprovalToken? = nil
    var saveLimit: (@MainActor (String) async throws -> Void)? = nil
    var walletName: String? = nil
    var tokenSymbol: String? = nil
    @Environment(\.oathLocalizer) private var strings
    @State private var identities: [String: ContractIdentity] = [:]
    @State private var showsWalletAddress = false
    @State private var showsAccessLimit = false
    @State private var showsAccessToken = false
    private var action: WalletConnectEVMAction { .init(request) }
    private var swap: WalletConnectSwapReview { .init(request) }
    static func isAccessReview(_ request: WalletConnectEVMRequest) -> Bool {
        let kind = WalletConnectEVMAction(request).kind
        return kind == .approval || kind == .operatorApproval
    }
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
        Group {
            if Self.isAccessReview(request) { accessReview }
            else { transactionReview }
        }
        .task(id: OathWCCallMetadata.Key(request)) {
            identities = [:]
            await OathWCCallMetadata.load(request: request, approvalToken: approvalToken) { identity in
                identities[identity.address] = identity
            }
        }
        .sheet(isPresented: $showsWalletAddress) {
            OathWalletSheet(title: .contactAddress) {
                OathAddressText(address: request.sender, identifier: "walletconnect.access.fullAddress")
                    .padding(.vertical, 16)
            }.oathLanguage(strings.language)
        }
        .navigationDestination(isPresented: $showsAccessLimit) { accessLimitDestination }
        .navigationDestination(isPresented: $showsAccessToken) {
            OathWCAddressDetails(address: request.recipient, title: .tokenContract, close: close)
        }
    }

    private var accessTokenIdentity: ContractIdentity? {
        identities[request.recipient].flatMap {
            $0.network == plan.network.rawValue && $0.address == request.recipient ? $0 : nil
        }
    }
    private var accessSymbol: String? { accessTokenIdentity?.symbol ?? tokenSymbol }
    private var accessAmount: String { action.fields.first { $0.label == .amount }?.value ?? "0" }
    private var accessLimit: String {
        if action.kind == .operatorApproval {
            return strings.text(action.fields.first { $0.label == .access }?.value == "1" ? .permissionAllItems : .permissionNone)
        }
        if action.isUnlimited { return strings.text(.permissionUnlimited) }
        return approvalToken.flatMap { $0.contract == request.recipient ? OathSendAmount.units(accessAmount, decimals: $0.decimals) : nil } ?? accessAmount
    }

    private var accessReview: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                if action.kind == .approval, approvalToken != nil {
                    accessHeadline(amount: accessLimit)
                } else {
                    Text(strings.text(action.kind == .operatorApproval ? .wcReviewPermissions
                        : approvalToken == nil ? .wcApprovalRawValue : .wcConfirmedLimit))
                        .oathFont(.body).foregroundStyle(.secondary)
                    if action.kind == .approval {
                        NavigationLink { accessLimitDestination } label: {
                            Text(accessLimit)
                                .underline(pattern: .dot, color: .gray.opacity(0.65))
                                .oathFont(.largeTitle, weight: .semibold, size: 46)
                                .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.6)
                                .padding(.vertical, 8).frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).oathNeutralControl()
                            .accessibilityLabel(strings.text(.wcConfirmedLimit))
                            .accessibilityValue(accessLimit)
                            .accessibilityIdentifier("walletconnect.transaction.limit")
                    } else {
                        Text(accessLimit).oathFont(.largeTitle, weight: .semibold, size: 46)
                            .multilineTextAlignment(.center)
                    }
                    accessHeadline(amount: nil)
                }
                Text(strings.text(action.kind == .operatorApproval ? .wcOperatorDetail
                    : approvalToken == nil ? .wcAmbiguousApproval : action.isUnlimited ? .wcUnlimitedDetail : .wcApprovalCallDetail))
                    .oathFont(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity).padding(.vertical, 12)
                .accessibilityIdentifier("walletconnect.approval.summary")

            VStack(spacing: 20) {
                OathWCAccessDetail(title: .walletTab) {
                    OathButton(feedback: .navigate) { showsWalletAddress = true } label: {
                        Text(verbatim: walletName ?? strings.text(.wcWalletUnavailable))
                            .underline(pattern: .dot, color: .gray.opacity(0.65))
                            .multilineTextAlignment(.trailing)
                            .padding(.vertical, 8).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).oathNeutralControl()
                        .accessibilityHint(strings.text(.sendShowAddress))
                        .accessibilityIdentifier("walletconnect.access.walletAddress")
                }
                OathHairline()
                if let spender = action.fields.first(where: { $0.label == .spender })?.value {
                    OathWCAccessDetail(title: .wcReviewSpender) {
                        NavigationLink {
                            OathWCAddressDetails(address: spender, title: .wcReviewSpender, close: close)
                        } label: {
                            Text(verbatim: spenderName(spender)).multilineTextAlignment(.trailing)
                                .padding(.vertical, 8).frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).oathNeutralControl()
                            .accessibilityIdentifier("walletconnect.transaction.spender")
                    }
                }
                OathHairline()
                OathWCAccessDetail(title: .transactionNetworkFee) {
                    NavigationLink { OathWCEVMFees(plan: plan, close: close) } label: {
                        HStack(spacing: 6) {
                            Text(OathSendAmount.units(String(plan.fee), decimals: 18) ?? "—")
                                .monospacedDigit().multilineTextAlignment(.trailing)
                            networkLogo
                            Text(verbatim: plan.network.symbol)
                        }.environment(\.layoutDirection, .leftToRight)
                            .padding(.vertical, 8).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).oathNeutralControl()
                        .accessibilityHint(strings.text(.wcMaximumFee))
                        .accessibilityIdentifier("walletconnect.transaction.fees")
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }

    private func accessHeadline(amount: String?) -> some View {
        OathWCAccessHeadline(amount: amount,
            symbol: accessSymbol ?? String(request.recipient.prefix(8)) + "…" + request.recipient.suffix(6),
            network: plan.network, editLimit: { showsAccessLimit = true }, showToken: { showsAccessToken = true })
    }

    @ViewBuilder private var networkLogo: some View {
        if let chain = OathImportChain(rawValue: plan.network.rawValue) {
            OathNetworkLogo(asset: chain.logoAsset, size: 18)
                .accessibilityLabel(chain.name)
        }
    }

    private func spenderName(_ address: String) -> String {
        let identity = identities[address].flatMap { $0.network == plan.network.rawValue && $0.address == address ? $0 : nil }
        return WalletConnectSpenderBrand.resolve(chainID: plan.network.chainID, address: address)?.name
            ?? identity?.name ?? strings.text(.permissionUnknown)
    }

    @ViewBuilder private var accessLimitDestination: some View {
        if let approvalToken, let saveLimit {
            OathWCApprovalLimit(token: approvalToken, networkID: plan.network.rawValue,
                identity: accessTokenIdentity, amount: accessAmount, save: saveLimit)
        } else {
            OathWCContent {
                OathWCValue(title: strings.text(.wcConfirmedLimit), value: accessAmount, leftToRight: true)
                OathSettingsFooter { Text(strings.text(.wcAmbiguousApproval)) }
            }.navigationTitle(strings.text(.wcConfirmedLimit)).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }
        }
    }

    private var transactionReview: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                if !Self.isAccessReview(request) {
                    Text(strings.text(swap.routes.isEmpty ? Self.title(action) : .wcReviewSwap)).oathFont(.title2, weight: .semibold)
                }
                if let approvalToken, let amount = action.fields.first(where: { $0.label == .amount })?.value {
                    OathWCApprovalSummary(networkID: plan.network.rawValue, token: approvalToken,
                        amount: amount, identity: identities[approvalToken.contract], compact: true)
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
            NavigationLink {
                OathWCAddressDetails(address: request.sender, title: .scannerWCAccount, close: close)
            } label: {
                OathSettingsRow(title: strings.text(.scannerWCAccount),
                    value: String(request.sender.prefix(8)) + "…" + request.sender.suffix(6), accessory: .disclosure)
            }.buttonStyle(OathSettingsRowButtonStyle())
            if request.call.bytes.isEmpty {
                NavigationLink {
                    OathWCAddressDetails(address: request.recipient, title: .sendRecipient, close: close)
                } label: {
                    OathSettingsRow(title: strings.text(.sendRecipient), value: request.recipient, accessory: .disclosure)
                }.buttonStyle(OathSettingsRowButtonStyle())
            }
            if action.kind == .approval || action.kind == .operatorApproval {
                OathSettingsFooter { Text(strings.text(action.kind == .operatorApproval ? .wcOperatorDetail : approvalToken == nil ? .wcAmbiguousApproval : .wcApprovalCallDetail)) }
            }
            ForEach(Array((swap.routes.isEmpty ? action.fields : []).enumerated()), id: \.offset) { _, field in
                if field.label == .amount, approvalToken != nil { EmptyView() }
                else if field.label == .spender {
                    OathWCSpenderRow(network: plan.network, address: field.value,
                        identity: identities[field.value], close: close)
                } else { OathWCValue(title: strings.text(field.label == .amount && action.kind == .approval && approvalToken == nil ? .wcApprovalRawValue : Self.label(field.label)), value: field.label == .access
                    ? strings.text(field.value == "1" ? .permissionAllItems : .permissionNone) : field.value, leftToRight: field.label != .access)
                }
            }
            if action.kind == .approval {
                NavigationLink {
                    if let approvalToken, let saveLimit {
                        OathWCApprovalLimit(token: approvalToken, networkID: plan.network.rawValue, identity: identities[approvalToken.contract], amount: action.fields.first { $0.label == .amount }?.value ?? "0", save: saveLimit)
                    } else { OathWCContent {
                        OathWCValue(title: strings.text(.wcConfirmedLimit), value: action.fields.first { $0.label == .amount }?.value ?? "—", leftToRight: true)
                        OathSettingsFooter { Text(strings.text(approvalToken == nil ? .wcAmbiguousApproval : action.isUnlimited ? .wcUnlimitedDetail : .wcApprovalCallDetail)) }
                    }.navigationTitle(strings.text(.wcConfirmedLimit)).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }
                    }
                } label: { OathSettingsRow(title: strings.text(.wcConfirmedLimit), icon: "slider.horizontal.3") }
                    .buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.transaction.limit")
            }
            OathSettingsSectionRule()
            NavigationLink {
                OathWCEVMFees(plan: plan, close: close)
            } label: {
                OathSettingsRow(title: strings.text(.wcMaximumFee), value: fee)
            }.buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.transaction.fees")
            if !request.call.bytes.isEmpty { OathSettingsFooter { Text(strings.text(.wcCallWarning)) } }
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

/// Format markers preserve translated word order and keep the amount link
/// separate from token metadata. The chain logo wraps with the sentence.
private struct OathWCAccessHeadline: View {
    let amount: String?
    let symbol: String
    let network: EVMSendNetwork
    let editLimit: () -> Void
    let showToken: () -> Void
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .title2) private var badgeSize: CGFloat = 22
    @ScaledMetric(relativeTo: .title2) private var badgeBaseline: CGFloat = -3
    @State private var badge: UIImage?
    private var chain: OathImportChain? { OathImportChain(rawValue: network.rawValue) }
    private var chainName: String { chain?.name ?? network.rawValue }
    private struct BadgeRequest: Equatable {
        let network: String
        let size: CGFloat
        let scale: CGFloat
        let scheme: ColorScheme
    }
    private var badgeRequest: BadgeRequest {
        .init(network: network.rawValue, size: badgeSize, scale: displayScale, scheme: colorScheme)
    }
    private func linked(_ value: String, destination: String, dotted: Bool) -> Text {
        var value = AttributedString(strings.invariant(value))
        value.foregroundColor = .primary
        value.link = URL(string: "oath-access://" + destination)
        if dotted { value.underlineStyle = Text.LineStyle(pattern: .dot, color: .gray.opacity(0.65)) }
        return Text(value)
    }
    private var headline: Text {
        let amountMarker = "{oath-access-amount}", symbolMarker = "{oath-access-symbol}", chainMarker = "{oath-access-chain}"
        let template = amount == nil ? strings.format(.sendAssetOnNetwork, symbolMarker, chainMarker)
            : strings.format(.wcApproveAmountOnNetwork, amountMarker, symbolMarker, chainMarker)
        let name = Text(verbatim: strings.invariant(chainName))
        let chainText: Text
        if let badge {
            let icon = Text(Image(uiImage: badge).renderingMode(.original)).baselineOffset(badgeBaseline)
            chainText = Text("\(icon) \(name)")
        } else { chainText = name }
        return template.components(separatedBy: chainMarker).enumerated().reduce(Text("")) { result, chainPart in
            let part = chainPart.element.components(separatedBy: symbolMarker).enumerated().reduce(Text("")) { result, symbolPart in
                let text = symbolPart.element.components(separatedBy: amountMarker).enumerated().reduce(Text("")) { result, amountPart in
                    Text("\(result)\(amountPart.offset == 0 ? Text("") : linked(amount ?? "", destination: "limit", dotted: true))\(Text(verbatim: amountPart.element))")
                }
                return Text("\(result)\(symbolPart.offset == 0 ? Text("") : linked(symbol, destination: "token", dotted: false))\(text)")
            }
            return Text("\(result)\(chainPart.offset == 0 ? Text("") : chainText)\(part)")
        }
    }
    var body: some View {
        headline.oathFont(.title2, weight: .semibold).foregroundStyle(.primary).tint(.primary)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8).frame(minHeight: 44)
            .accessibilityIdentifier("walletconnect.access.headline")
            .accessibilityActions {
                if amount != nil { Button(strings.text(.wcConfirmedLimit), action: editLimit) }
                Button(strings.text(.tokenContract), action: showToken)
            }
            .environment(\.openURL, OpenURLAction { url in
                switch url.absoluteString {
                case "oath-access://limit" where amount != nil: editLimit()
                case "oath-access://token": showToken()
                default: return .discarded
                }
                OathHaptics.shared.play(.navigate)
                return .handled
            })
            .task(id: badgeRequest) {
                badge = nil
                guard let chain else { return }
                let renderer = ImageRenderer(content: OathNetworkLogo(asset: chain.logoAsset, size: badgeSize)
                    .environment(\.colorScheme, colorScheme))
                renderer.scale = displayScale
                badge = renderer.uiImage
                if badge == nil, !Task.isCancelled {
                    OathDiagnostics.$operationID.withValue(UUID()) {
                        OathDiagnostics.record(DiagnosticFailure("access_network_logo_render_failed"),
                            component: "walletconnect", operation: "access_network_logo", context: ["chain": chain.id])
                    }
                }
            }
    }
}

private struct OathWCAccessDetail<Value: View>: View {
    let title: OathStringKey
    @ViewBuilder let value: () -> Value
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                Text(strings.text(title)).foregroundStyle(.secondary).padding(.top, 10)
                Spacer(minLength: 0)
                value()
            }.fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(strings.text(title)).foregroundStyle(.secondary)
                value()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.oathFont(.body).foregroundStyle(.primary)
    }
}

struct OathWCAccessFooterNotice: View {
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        Text(strings.text(.wcCallWarning)).oathFont(.footnote).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity).padding(.horizontal, 8).padding(.bottom, 4)
            .accessibilityIdentifier("walletconnect.access.caution")
    }
}

/// Shared by the pre-sign review and post-submission receipt. Metadata is
/// presentation only; the exact network/address remains the spender identity.
struct OathWCSpenderRow: View {
    let network: EVMSendNetwork
    let address: String
    let identity: ContractIdentity?
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        let brand = WalletConnectSpenderBrand.resolve(chainID: network.chainID, address: address)
        let checkedIdentity = identity.flatMap { $0.network == network.rawValue && $0.address == address ? $0 : nil }
        NavigationLink {
            OathWCAddressDetails(address: address, title: .wcSpender, close: close)
        } label: {
            HStack(spacing: 12) {
                Text(strings.text(.wcSpender)).oathFont(.body)
                Spacer(minLength: 12)
                OathDAppLogo(icons: brand.map { [$0.iconURL] } ?? [], size: 28)
                Text(verbatim: brand?.name ?? checkedIdentity?.name ?? strings.text(.permissionUnknown))
                    .oathFont(.body, weight: .semibold).multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }.foregroundStyle(.primary).padding(20).contentShape(Rectangle())
        }.buttonStyle(OathSettingsRowButtonStyle())
            .accessibilityIdentifier("walletconnect.transaction.spender")
    }
}

struct OathWCApprovalSummary: View {
    let networkID: String
    let token: WalletConnectApprovalToken
    let amount: String
    let identity: ContractIdentity?
    var compact = false
    var body: some View {
        OathWCTokenAccessSummary(networkID: networkID, reference: token.contract, amount: amount,
            decimals: token.decimals, isUnlimited: amount == WalletConnectEVMAction.maximum, identity: identity, compact: compact)
    }
}

struct OathWCTokenAccessSummary: View {
    let networkID: String
    let reference: String
    let amount: String
    let decimals: Int?
    let isUnlimited: Bool
    let identity: ContractIdentity?
    var compact = false
    @Environment(\.oathLocalizer) private var strings
    private var checkedIdentity: ContractIdentity? {
        identity.flatMap { $0.network == networkID && $0.address == reference ? $0 : nil }
    }
    var body: some View {
        VStack(spacing: 12) {
            OathWCReviewTokenLogo(networkID: networkID, reference: reference,
                symbol: checkedIdentity?.symbol, size: compact ? 32 : 64)
            if let symbol = checkedIdentity?.symbol { Text(verbatim: symbol).oathFont(.headline) }
            Text(isUnlimited ? strings.text(.permissionUnlimited)
                : decimals.flatMap { OathSendAmount.units(amount, decimals: $0) } ?? amount)
                .oathFont(compact ? .title3 : .largeTitle, weight: .semibold).minimumScaleFactor(0.6).lineLimit(2)
                .environment(\.layoutDirection, .leftToRight)
            if !compact || (decimals == nil && !isUnlimited) {
                Text(strings.text(decimals == nil && !isUnlimited ? .wcRawAmount : .wcConfirmedLimit))
                    .oathFont(.subheadline).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity).multilineTextAlignment(.center)
            .accessibilityIdentifier("walletconnect.approval.summary")
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
    var closeIdentifier = "walletconnect.transaction.close"
    var body: some View {
        OathWCResultContent(identity: identity) {
            OathWCEVMCompletionStatus(transaction: transaction)
        }.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OathCloseButton(action: close).accessibilityIdentifier(closeIdentifier)
            }
        }
        .toolbar(.hidden, for: .bottomBar)
    }
}

private struct OathWCEVMCompletionStatus: View {
    let transaction: OathWalletConnectService.TransactionCompletion
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
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 56)).foregroundStyle(failed ? Color.red : OathOnboardingColors.blue)
            Text(strings.text(title))
                .oathFont(.title2, weight: .semibold)
                .accessibilityIdentifier("walletconnect.transaction.status")
            Text(strings.text(detail))
                .oathFont(.body).foregroundStyle(.secondary)
        }.multilineTextAlignment(.center)
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
        }.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OathDoneButton(action: close).accessibilityIdentifier("walletconnect.gas.done")
            }
        }
        .toolbar(.hidden, for: .bottomBar)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) }
            }
            .oathBottomActions {
                OathBottomAction(title: strings.text(.copyAddress), identifier: "walletconnect.gas.copy",
                                 appearance: .secondary) { OathClipboard.copy(address) }
            }
            .task(id: address) {
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
    let networkID: String
    let identity: ContractIdentity?
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
            VStack(spacing: 12) {
                OathWCReviewTokenLogo(networkID: networkID, reference: token.contract, symbol: identity?.symbol, size: 64)
                if let symbol = identity?.symbol { Text(verbatim: symbol).oathFont(.headline) }
                if unlimited {
                    Text(strings.text(.permissionUnlimited)).oathFont(.title2, weight: .semibold)
                }
            }.frame(maxWidth: .infinity).padding(.top, 24)
            if !unlimited {
                TextField(strings.text(.wcConfirmedLimit), text: $input)
                    .keyboardType(.decimalPad).oathFont(.largeTitle, weight: .semibold)
                    .multilineTextAlignment(.center).padding(24).disabled(working)
                    .accessibilityIdentifier("walletconnect.limit.input")
            }
            Toggle(strings.text(.permissionUnlimited), isOn: $unlimited)
                .oathSwitchStyle()
                .oathFont(.body).padding(20).disabled(working)
                .accessibilityIdentifier("walletconnect.limit.unlimited")
            OathSettingsFooter { Text(strings.text(unlimited ? .wcUnlimitedDetail : .wcEditableApprovalDetail)) }
            OathWCValue(title: strings.text(.wcTokenBalance), value: OathSendAmount.units(token.balance, decimals: token.decimals) ?? token.balance, leftToRight: true)
            if failed { OathSettingsFooter { Text(strings.text(.wcLimitFailed)).foregroundStyle(.red) } }
        }
        .navigationTitle(strings.text(.wcConfirmedLimit)).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            OathToolbarAction(title: .save, isEnabled: atomic != nil && !working,
                              isWorking: working, identifier: "walletconnect.limit.save") {
                guard let atomic, !working else { return }
                working = true; failed = false
                saveTask = Task { @MainActor in
                    await OathDiagnostics.$operationID.withValue(UUID()) {
                        defer { working = false }
                        do { try await save(atomic); try Task.checkCancellation(); dismiss() }
                        catch is CancellationError { }
                        catch {
                            OathDiagnostics.record(error, component: "walletconnect", operation: "revise_approval")
                            failed = true
                        }
                    }
                }
            }
        }
        .toolbar(.hidden, for: .bottomBar)
        .onAppear {
            unlimited = amount == WalletConnectEVMAction.maximum
            input = OathSendAmount.units(unlimited ? "0" : amount, decimals: token.decimals) ?? "0"
        }.onDisappear { saveTask?.cancel() }
    }
}
