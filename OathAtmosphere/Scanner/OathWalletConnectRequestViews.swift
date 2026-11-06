import SwiftUI
import OathAnkr

struct OathWCMessageReview: View {
    let message: String
    let signIn: WalletConnectSignIn?
    let account: String
    let network: String
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        VStack(spacing: 0) {
            if let signIn {
                VStack(spacing: 10) {
                    Text(strings.text(.wcSignInTitle)).oathFont(.title2, weight: .semibold)
                    Text(strings.text(.wcSignInDetail)).oathFont(.subheadline).foregroundStyle(.secondary)
                }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(24)
                OathWCValue(title: strings.text(.wcWebsiteDetails), value: signIn.domain, leftToRight: true)
                OathWCValue(title: strings.text(.tokenNetwork), value: network, leftToRight: true)
                if let expires = signIn.expiration {
                    OathWCValue(title: strings.text(.wcExpires), value: expires.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(strings.language.locale)))
                }
                if let statement = signIn.statement {
                    Text(statement).oathFont(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
                if !signIn.resources.isEmpty {
                    OathSettingsFooter { Text(strings.text(.wcSignInResourcesDetail)) }
                }
            } else {
                Text(message).oathFont(.body).lineLimit(8).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    .background(Color(uiColor: OathSurfaceColors.field), in: .rect(cornerRadius: 20))
                    .padding(.horizontal, 20).padding(.vertical, 12)
                OathWCValue(title: strings.text(.tokenNetwork), value: network, leftToRight: true)
            }
            OathWCValue(title: strings.text(.scannerWCAccount), value: account, leftToRight: true)
            OathWCValue(title: strings.text(.transactionNetworkFee), value: strings.text(.wcNoSigningFee))
            NavigationLink {
                OathWCMessageDetails(message: message, close: close)
            } label: {
                OathSettingsRow(title: strings.text(.wcFullMessage), icon: "text.alignleft")
            }.buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.message.details")
            NavigationLink {
                OathWCSignatureHelp(close: close)
            } label: {
                OathSettingsRow(title: strings.text(.wcAboutSignature), icon: "info.circle")
            }.buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.signature.help")
            OathSettingsFooter { Text(strings.text(.wcTypedWarning)) }
        }
    }
}

struct OathWCMessageDetails: View {
    let message: String
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathWCContent {
            Text(message).oathFont(.body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }.navigationTitle(strings.text(.wcFullMessage)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }

    }
}

struct OathWCSignatureHelp: View {
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathWCContent {
            OathSettingsRow(title: strings.text(.wcRequestsYouApprove), icon: "signature", accessory: .none)
            OathSettingsFooter { Text(strings.text(.wcTypedWarning)) }
            OathSettingsRow(title: strings.text(.wcSpender), icon: "hand.raised", accessory: .none)
            OathSettingsFooter { Text(strings.text(.wcSignedPermissionDetail)) }
            OathSettingsRow(title: strings.text(.wcSignatureDeadline), icon: "clock", accessory: .none)
            OathSettingsFooter { Text(strings.text(.wcPermitDeadlineDetail)); Text(strings.text(.wcPermit2AllowanceDetail)) }
            OathSettingsSectionRule()
            OathSettingsFooter { Text(strings.text(.wcDisconnectDetail)) }
        }.navigationTitle(strings.text(.wcAboutSignature)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }

    }
}

/// Declining is a completed cancellation, not a success to confirm.
/// Keep the message centered in the available sheet area, with scrolling only
/// when larger accessibility text needs more space than the viewport.
struct OathWCDeclinedPage: View {
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        OathWCResultContent(identity: nil) {
            VStack(spacing: 22) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(OathOnboardingColors.blue)
                    .accessibilityHidden(true)
                Text(strings.text(.wcRequestDeclined)).oathFont(.title2, weight: .semibold)
                Text(strings.text(.wcRequestDeclinedDetail)).oathFont(.body).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OathCloseButton(action: close).accessibilityIdentifier("walletconnect.declined.close")
            }
        }
    }
}

struct OathWCStatePage: View {
    let title: OathStringKey
    let detail: OathStringKey
    let symbol: String
    var identity: OathWCIdentity? = nil
    var isError = false
    var isWorking = false
    var primaryTitle: OathStringKey = .done
    var secondaryTitle: OathStringKey? = nil
    let primary: () -> Void
    var secondary: (() -> Void)? = nil
    var closeIdentifier = "walletconnect.state.close"
    @Environment(\.oathLocalizer) private var strings
    private var usesTopConfirmation: Bool { [.done, .save, .apply].contains(primaryTitle) }
    private var showsBottomActions: Bool {
        !isWorking && (!usesTopConfirmation || (secondaryTitle != nil && secondary != nil))
    }
    private var statusContent: some View {
        VStack(spacing: 22) {
            if isWorking { ProgressView().controlSize(.large).tint(OathOnboardingColors.blue) }
            else {
                Image(systemName: symbol).font(.system(size: 56, weight: .regular))
                    .foregroundStyle(isError ? Color.red : OathOnboardingColors.blue).accessibilityHidden(true)
            }
            Text(strings.text(title)).oathFont(.title2, weight: .semibold)
            Text(strings.text(detail)).oathFont(.body).foregroundStyle(.secondary)
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
    }
    var body: some View {
        OathWCResultContent(identity: identity,
                            identityIdentifier: title == .scannerWCConnected
                                ? "walletconnect.connected.identity" : "walletconnect.result.identity") {
            statusContent
        }.toolbar {
            if !isWorking {
                if usesTopConfirmation {
                    ToolbarItem(placement: .topBarTrailing) {
                        if title == .scannerWCConnected {
                            OathCloseButton { primary() }
                                .accessibilityIdentifier(closeIdentifier)
                        } else {
                            OathDoneButton(label: primaryTitle) { primary() }
                                .accessibilityIdentifier("walletconnect.state.primary")
                        }
                    }
                }
            }
        }
        .oathBottomActions(isPresented: showsBottomActions) {
            VStack(spacing: OathActionMetrics.spacing) {
                if !usesTopConfirmation {
                    OathBottomAction(title: strings.text(primaryTitle), identifier: "walletconnect.state.primary", action: primary)
                }
                if let secondaryTitle, let secondary {
                    OathBottomAction(title: strings.text(secondaryTitle), identifier: "walletconnect.state.secondary",
                                     appearance: .secondary, action: secondary)
                }
            }
        }
    }
}

/// Keep result messages centered above the dApp identity and native actions.
/// Intrinsic measurements let the existing sheet resize for every result type.
struct OathWCResultContent<Content: View>: View {
    let identity: OathWCIdentity?
    var identityIdentifier = "walletconnect.result.identity"
    @ViewBuilder let content: () -> Content

    var body: some View {
        OathEmptyStateScrollView {
            content().fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24).padding(.vertical, 40)
                .oathWCMeasureResult(.message)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) { identityFooter }
    }

    @ViewBuilder private var identityFooter: some View {
        if let identity {
            VStack(spacing: 8) {
                OathDAppLogo(icons: identity.icons, size: 44)
                    .padding(.bottom, 4)
                Text(identity.displayName).oathFont(.body, weight: .semibold)
                Text(identity.domain).oathFont(.subheadline).foregroundStyle(.secondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 700).frame(maxWidth: .infinity)
            .padding(.horizontal, 24).padding(.vertical, 20)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identityIdentifier)
            .oathWCMeasureResult(.identity)
        }
    }
}
