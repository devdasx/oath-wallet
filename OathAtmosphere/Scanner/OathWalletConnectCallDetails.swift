import SwiftUI
import OathAnkr
import OathDiagnostics

/// A readable review first; the original, copyable calldata stays one tap away.
struct OathWCCallDetails: View {
    let request: WalletConnectEVMRequest
    let close: @MainActor () -> Void
    var approvalToken: WalletConnectApprovalToken? = nil
    var initialIdentities: [String: ContractIdentity] = [:]
    @Environment(\.oathLocalizer) private var strings
    @State private var identities: [String: ContractIdentity] = [:]
    private var network: EVMSendNetwork? { EVMSendNetwork.allCases.first { $0.chainID == request.chainID } }
    private var action: WalletConnectEVMAction { .init(request) }

    var body: some View {
        let details = WalletConnectCallDetails(request)
        let swap = WalletConnectSwapReview(request)
        OathWCContent {
            VStack(spacing: 12) {
                Image(systemName: details.steps.contains { $0.operation == .swap } ? "arrow.triangle.swap" : "doc.text.magnifyingglass")
                    .font(.largeTitle).foregroundStyle(.primary)
                    .padding().background(Color(uiColor: OathSurfaceColors.field), in: Circle())
                Text(strings.text(details.steps.contains { $0.operation == .swap } ? .wcReviewSwap : OathWCEVMReview.title(action)))
                    .oathFont(.title2, weight: .semibold)
                if let chain = network.flatMap({ OathImportChain(rawValue: $0.rawValue) }) {
                    HStack(spacing: 8) {
                        OathNetworkLogo(asset: chain.logoAsset, size: 20)
                        Text(strings.invariant(chain.name)).oathFont(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(24)
                .accessibilityIdentifier("walletconnect.call.summary")

            if !swap.routes.isEmpty {
                OathWCSwapSummary(request: request, review: swap, identities: identities)
            }
            if (action.kind == .contract && !details.isRouter) || (details.isRouter && !details.fullyDecoded) {
                OathSettingsFooter { Text(strings.text(.wcDecodedUnavailable)) }
            }
            OathWCValue(title: strings.text(.scannerWCAccount), value: request.sender, leftToRight: true)
            OathWCValue(title: strings.text(request.call.bytes.isEmpty ? .sendRecipient : .wcContractAddress), value: request.recipient, leftToRight: true)
            OathWCValue(title: strings.text(.wcCallValue), value: nativeAmount(request.value), leftToRight: true)

            if details.isRouter {
                if let deadline = details.deadline { value(.init(label: .deadline, value: deadline)) }
                ForEach(Array(details.steps.enumerated()), id: \.offset) { index, step in
                    OathSettingsSectionRule()
                    HStack(spacing: 12) {
                        Text(strings.number(index + 1)).oathFont(.subheadline, weight: .semibold)
                            .padding(10).background(Color(uiColor: OathSurfaceColors.field), in: Circle())
                        Text(strings.text(title(step.operation))).oathFont(.headline)
                        Spacer(minLength: 0)
                    }.padding(20)
                    if step.optional { OathSettingsFooter { Text(strings.text(.wcOptionalStep)) } }
                    if step.operation == .unknown { OathSettingsFooter { Text(strings.text(.wcDecodedUnavailable)) } }
                    ForEach(Array(step.values.enumerated()), id: \.offset) { _, field in value(field) }
                }
            } else {
                ForEach(Array(action.fields.enumerated()), id: \.offset) { _, field in
                    // Approve is shared by ERC-20/ERC-721. Only verified allowance
                    // metadata permits a decimal token amount in that case.
                    if !(request.call.bytes.isEmpty && field.label == .recipient) {
                        value(.init(label: field.label, value: field.value, token: token(for: field.label)))
                    }
                }
            }
            OathSettingsSectionRule()
            NavigationLink {
                OathWCRawCallDetails(request: request, method: details.method, close: close)
            } label: { OathSettingsRow(title: strings.text(.wcTransactionData), icon: "curlybraces") }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("walletconnect.call.technical")
            if !request.call.bytes.isEmpty { OathSettingsFooter { Text(strings.text(.wcCallWarning)) } }
        }
        .navigationTitle(strings.text(.assetTransaction)).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }
        .task(id: OathWCCallMetadata.Key(request)) {
            identities = initialIdentities
            await OathWCCallMetadata.load(request: request, approvalToken: approvalToken, cached: initialIdentities) { identity in
                identities[identity.address] = identity
            }
        }
    }

    private func title(_ operation: WalletConnectCallDetails.Operation) -> OathStringKey {
        switch operation {
        case .swap: .wcReviewSwap
        case .transfer: .send
        case .wrap: .wcWrapNative
        case .unwrap: .wcUnwrapNative
        case .balanceCheck: .wcTokenBalance
        case .unknown: .wcContractCall
        }
    }
    private func nativeAmount(_ amount: String) -> String {
        (OathSendAmount.units(amount, decimals: 18) ?? amount) + " " + (network?.symbol ?? "")
    }
    private func token(for label: WalletConnectEVMAction.Label) -> String? {
        if action.kind == .swap {
            if label == .amount { return action.fields.first { $0.label == .tokenIn }?.value }
            if label == .minimumReceived { return action.fields.first { $0.label == .tokenOut }?.value }
        }
        return label == .amount && (action.kind == .transfer || approvalToken != nil) ? request.recipient : nil
    }
    @ViewBuilder private func value(_ field: WalletConnectCallDetails.Value) -> some View {
        let metadata = field.token.flatMap { identities[$0] }
        let decimals = field.token == request.recipient ? approvalToken?.decimals ?? metadata?.decimals : metadata?.decimals
        let formatted = field.token == "native" || field.token == "0x" + String(repeating: "0", count: 40)
            ? nativeAmount(field.value) : decimals.flatMap { OathSendAmount.units(field.value, decimals: $0) }.map { $0 + " " + (metadata?.symbol ?? "") }
        let date = field.label == .deadline ? Double(field.value).flatMap { $0 >= 0 && $0 < 253_402_300_800 ? Date(timeIntervalSince1970: $0) : nil } : nil
        let display: String = if field.routerBalance { strings.text(.wcRouterBalance) }
            else if let date { date.formatted(.dateTime.day().month().year().hour().minute().timeZone().locale(strings.language.locale)) }
            else if field.label == .access { strings.text(field.value == "1" ? .permissionAllItems : .permissionNone) }
            else { formatted ?? field.value }
        let label: OathStringKey = if field.label == .amount && (formatted != nil || field.routerBalance) { .sendAmount }
            else if field.label == .minimumReceived && formatted != nil { .historyMinimum }
            else { OathWCEVMReview.label(field.label) }
        if [.tokenIn, .tokenOut].contains(field.label), ["native", "0x" + String(repeating: "0", count: 40)].contains(field.value) {
            OathWCValue(title: strings.text(label), value: network?.symbol ?? field.value, leftToRight: true)
        } else if [.tokenIn, .tokenOut].contains(field.label), let token = identities[field.value] {
            OathWCValue(title: strings.text(label), value: token.name, leftToRight: true)
            OathSettingsFooter { Text(verbatim: field.value).textSelection(.enabled).environment(\.layoutDirection, .leftToRight) }
        } else {
            OathWCValue(title: strings.text(label),
                value: display, leftToRight: date == nil && !field.routerBalance && field.label != .access)
        }
        if field.label == .maximumSpent && formatted == nil {
            OathSettingsFooter { Text(strings.text(.wcRawAmount)) }
        }
    }

}

private struct OathWCRawCallDetails: View {
    let request: WalletConnectEVMRequest
    let method: String?
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathWCContent {
            if let method { OathWCValue(title: strings.text(.wcCallMethod), value: method, leftToRight: true) }
            OathSettingsFooter { Text(strings.text(.wcTransactionDataDetail)) }
            Text(verbatim: request.call.hex).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).environment(\.layoutDirection, .leftToRight)
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .accessibilityIdentifier("walletconnect.call.bytes")
        }
        .navigationTitle(strings.text(.wcTransactionData)).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }
    }
}

/// The network comes from the validated signing request, never dApp branding.
struct OathWCNetworkBadge: View {
    let chainID: UInt64
    private var network: EVMSendNetwork? { EVMSendNetwork.allCases.first { $0.chainID == chainID } }
    var body: some View {
        HStack(spacing: 8) {
            if let chain = network.flatMap({ OathImportChain(rawValue: $0.rawValue) }) {
                OathNetworkLogo(asset: chain.logoAsset, size: 20)
                Text(verbatim: chain.name).oathFont(.subheadline, weight: .semibold)
            } else {
                Text(verbatim: network?.rawValue ?? "eip155:\(chainID)").oathFont(.subheadline, weight: .semibold)
            }
        }.foregroundStyle(.secondary)
            .accessibilityIdentifier("walletconnect.swap.network")
    }
}

struct OathWCSwapSummary: View {
    let request: WalletConnectEVMRequest
    let review: WalletConnectSwapReview
    let identities: [String: ContractIdentity]
    @Environment(\.oathLocalizer) private var strings
    private var network: EVMSendNetwork? { EVMSendNetwork.allCases.first { $0.chainID == review.chainID } }

    var body: some View {
        VStack(spacing: 0) {
            if review.incomplete { OathSettingsFooter { Text(strings.text(.wcDecodedUnavailable)) } }
            ForEach(Array(review.routes.enumerated()), id: \.offset) { index, route in
                if review.routes.count > 1 {
                    OathSettingsSectionRule()
                    Text(strings.text(.wcReviewSwap) + " " + strings.number(index + 1))
                        .oathFont(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
                if route.optional { OathSettingsFooter { Text(strings.text(.wcOptionalStep)) } }
                asset(route.input, title: .wcTokenIn)
                    .accessibilityIdentifier("walletconnect.swap.input.\(index)")
                Image(systemName: "arrow.down").font(.title3).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).accessibilityHidden(true)
                asset(route.output, title: .wcTokenOut)
                    .accessibilityIdentifier("walletconnect.swap.output.\(index)")
                // Destination is visible even when the dApp sends output elsewhere.
                OathWCValue(title: strings.text(.sendRecipient), value: route.recipient, leftToRight: true)
            }
            ForEach(Array(review.nativeConversions.enumerated()), id: \.offset) { _, step in
                OathSettingsSectionRule()
                OathWCValue(title: strings.text(step.operation == .wrap ? .wcWrapNative : .wcUnwrapNative),
                    value: network?.symbol ?? "—", leftToRight: true)
                if step.optional { OathSettingsFooter { Text(strings.text(.wcOptionalStep)) } }
                if let recipient = step.values.first(where: { $0.label == .recipient })?.value {
                    OathWCValue(title: strings.text(.sendRecipient), value: recipient, leftToRight: true)
                }
            }
        }
    }

    private func asset(_ asset: WalletConnectSwapReview.Asset, title: OathStringKey) -> some View {
        let native = asset.reference == "native"
        let identity = identities[asset.reference].flatMap { $0.network == network?.rawValue ? $0 : nil }
        let symbol = native ? network?.symbol : identity?.symbol
        let decimals = native ? 18 : identity?.decimals
        let amount = decimals.flatMap { OathSendAmount.units(asset.amount, decimals: $0) }
        let bound: OathStringKey = switch asset.bound {
        case .exact: .sendAmount
        case .minimum: .historyMinimum
        case .maximum: .historyMaximum
        case .routerBalance: .wcRouterBalance
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text(strings.text(title)).oathFont(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 12) {
                if native, let chain = network.flatMap({ OathImportChain(rawValue: $0.rawValue) }) {
                    OathNetworkLogo(asset: chain.logoAsset, size: 40)
                } else {
                    OathTokenLogo(source: nil, symbol: symbol ?? "", size: 40,
                        identity: network.flatMap { chain in decimals.flatMap {
                            .init(networkID: chain.rawValue, reference: asset.reference, decimals: $0)
                        } })
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: native ? (symbol ?? "—") : (identity?.name ?? asset.reference))
                        .oathFont(.headline).textSelection(.enabled)
                        .environment(\.layoutDirection, .leftToRight)
                        .fixedSize(horizontal: false, vertical: true)
                    OathWCNetworkBadge(chainID: review.chainID)
                }
            }
            if asset.bound == .routerBalance {
                Text(strings.text(.wcRouterBalance)).oathFont(.title3, weight: .semibold)
            } else {
                Text(strings.text(bound)).oathFont(.caption).foregroundStyle(.secondary)
                Text(verbatim: (amount ?? asset.amount) + (symbol.map { " " + $0 } ?? ""))
                    .oathFont(.title2, weight: .semibold).textSelection(.enabled)
                    .environment(\.layoutDirection, .leftToRight).fixedSize(horizontal: false, vertical: true)
                if amount == nil {
                    Text(strings.text(.wcRawAmount)).oathFont(.caption).foregroundStyle(.secondary)
                }
            }
            // A name or logo is not an identity guarantee: retain the full
            // contract alongside it, including when two tokens share a symbol.
            if !native, identity != nil {
                Text(verbatim: asset.reference).oathFont(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).environment(\.layoutDirection, .leftToRight)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
    }
}

/// Bounded parallel metadata shared by approval and detail presentation. Optional
/// absent metadata is not a failure; transport/provider failures are reported by
/// the shared identity service. Request bytes and addresses never enter reports.
@MainActor enum OathWCCallMetadata {
    struct Key: Hashable {
        let chain: UInt64
        let sender: String, recipient: String, value: String, data: String
        init(_ request: WalletConnectEVMRequest) {
            chain = request.chainID; sender = request.sender; recipient = request.recipient
            value = request.value; data = request.call.hex
        }
    }
    static func load(request: WalletConnectEVMRequest, approvalToken: WalletConnectApprovalToken?,
                     cached: [String: ContractIdentity] = [:],
                     receive: @MainActor (ContractIdentity) -> Void) async {
        guard let network = EVMSendNetwork.allCases.first(where: { $0.chainID == request.chainID }) else { return }
        let details = WalletConnectCallDetails(request), action = WalletConnectEVMAction(request)
        var references = details.steps.flatMap(\.values).compactMap(\.token)
        if action.kind == .transfer || approvalToken != nil { references.append(request.recipient) }
        if action.kind == .swap { references += action.fields.filter { [.tokenIn, .tokenOut].contains($0.label) }.map(\.value) }
        let tokens = Array(Set(references.filter {
            $0.hasPrefix("0x") && $0 != "0x" + String(repeating: "0", count: 40) && cached[$0]?.network != network.rawValue
        }).sorted().prefix(12))
        await OathDiagnostics.$chain.withValue(network.rawValue) {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                await withTaskGroup(of: ContractIdentity?.self) { group in
                    var next = 0
                    func enqueue() {
                        guard next < tokens.count, !Task.isCancelled else { return }
                        let token = tokens[next]; next += 1
                        group.addTask {
                            await OathDiagnostics.attemptOptional("walletconnect_call_metadata") {
                                try await OathPermissionService.shared.identity(network: network.rawValue, address: token, asset: true)
                            }
                        }
                    }
                    for _ in 0..<min(3, tokens.count) { enqueue() }
                    for await identity in group {
                        guard !Task.isCancelled else { group.cancelAll(); return }
                        if let identity { receive(identity) }
                        enqueue()
                    }
                }
            }
        }
    }
}
