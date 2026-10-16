import SwiftUI
import OathAnkr

/// The actual fields of the immutable signing request, never peer-supplied
/// display summaries. Token metadata may enrich this view, but cannot replace
/// the contract/atomic amount that identifies what is being authorized.
struct OathWalletConnectTypedReview: View {
    let data: WalletConnectTypedData
    let account: String
    let network: String
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 8) {
                Text(strings.text(data.permission == nil ? .wcTypedReviewTitle : .wcPermitReviewTitle))
                    .oathFont(.title2, weight: .semibold)
                Text(strings.text(data.permission == nil ? .wcTypedReviewDetail : .wcPermitReviewDetail))
                    .oathFont(.subheadline).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 8)
            VStack(spacing: 14) {
                value(.tokenNetwork, network)
                value(.scannerWCAccount, account)
                if let name = data.domain["name"].string { value(.wcSigningDomain, WalletConnectTypedData.visible(name)) }
                if let contract = data.verifyingContract { value(.wcVerifyingContract, contract) }
                if let permission = data.permission { permissionSummary(permission) }
                else { value(.wcSignedType, data.primaryType) }
                value(.transactionNetworkFee, strings.text(.wcNoSigningFee))
            }
            Text(strings.text(warning)).oathFont(.footnote).foregroundStyle(.secondary)
            if data.chainID == nil {
                Text(strings.text(.wcNoChainBinding)).oathFont(.footnote).foregroundStyle(.orange)
            }
            NavigationLink {
                OathWalletConnectSignedFields(data: data, close: close)
            } label: {
                HStack {
                    Text(strings.text(.wcAllSignedFields)).oathFont(.body)
                    Spacer()
                    Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                }.padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("walletconnect.typed.fields")
            NavigationLink { OathWCSignatureHelp(close: close) } label: {
                HStack {
                    Text(strings.text(.wcAboutSignature)).oathFont(.body)
                    Spacer()
                    Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                }.padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("walletconnect.signature.help")
        }
    }
    private var warning: OathStringKey {
        switch data.permission {
        case .erc2612: .wcPermitDeadlineDetail
        case .permit2Allowance: .wcPermit2AllowanceDetail
        case .permit2Transfer: .wcPermit2TransferDetail
        case nil: .wcTypedWarning
        }
    }
    @ViewBuilder private func permissionSummary(_ permission: WalletConnectTypedData.Permission) -> some View {
        switch permission {
        case .erc2612(let token, _, let spender, let amount, let nonce, let deadline):
            value(.wcTokenContract, token); value(.wcSpender, spender); value(.wcAtomicLimit, amount)
            value(.wcNonce, nonce); value(.wcSignatureDeadline, date(deadline))
        case .permit2Allowance(let token, let spender, let amount, let nonce, let expiration, let deadline):
            value(.wcTokenContract, token); value(.wcSpender, spender); value(.wcAtomicLimit, amount)
            value(.wcNonce, nonce); value(.wcAllowanceExpiry, date(expiration)); value(.wcSignatureDeadline, date(deadline))
        case .permit2Transfer(let token, let spender, let amount, let nonce, let deadline):
            value(.wcTokenContract, token); value(.wcSpender, spender); value(.wcAtomicLimit, amount)
            value(.wcNonce, nonce); value(.wcSignatureDeadline, date(deadline))
        }
    }
    private func value(_ key: OathStringKey, _ value: String) -> some View {
        OathWCValue(title: strings.text(key), value: value, leftToRight: true)
    }
    private func date(_ raw: String) -> String {
        guard let seconds = UInt64(raw), seconds > 0, seconds < 253_402_300_800 else { return raw }
        return Date(timeIntervalSince1970: Double(seconds)).formatted(.dateTime.day().month().year().hour().minute().timeZone().locale(strings.language.locale))
    }
}

struct OathWalletConnectSignedFields: View {
    let data: WalletConnectTypedData
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text(strings.text(.wcSignedFieldsDetail)).oathFont(.subheadline).foregroundStyle(.secondary)
                ForEach(Array(data.fields.enumerated()), id: \.offset) { _, field in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(field.path).oathFont(.subheadline, weight: .semibold)
                        Text(field.type).oathFont(.caption).foregroundStyle(.secondary)
                        Text(field.value).oathFont(.body).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.layoutDirection, .leftToRight)
                    OathHairline()
                }
            }.padding(24)
        }.background(Color(uiColor: OathSurfaceColors.canvas))
            .navigationTitle(strings.text(.wcAllSignedFields)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }
            .oathNativeLocalization()
    }
}
