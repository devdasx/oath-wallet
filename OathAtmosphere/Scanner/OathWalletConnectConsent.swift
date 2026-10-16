import SwiftUI

/// Presentation values are public metadata only. Consent is committed by the
/// service after reloading ownership and rebuilding the negotiated namespaces.
struct OathWCIdentity {
    enum Verification { case matched, unknown, blocked }
    let name: String
    let url: String
    let icons: [String]
    let origin: String?
    let verification: Verification
    var displayName: String { OathWalletConnectPolicy.displayName(name) }
    var domain: String { OathWalletConnectPolicy.safeHost(url) ?? "—" }
}

struct OathWCWalletChoice: Identifiable {
    let id: String
    let name: String
}
struct OathWCNetworkChoice: Identifiable {
    let id: String
    let name: String
    let logo: String?
    let address: String?
    let required: Bool
}
struct OathWCMethodGroup: Identifiable {
    let id: String
    let methods: [String]
    let events: [String]
}

/// Uses the same open rows, neutral icon tiles and blue native confirmations as
/// Settings. Every drill-down pushes inside the existing large sheet.
struct OathWalletConnectConsent: View {
    let identity: OathWCIdentity
    let wallets: [OathWCWalletChoice]
    let networks: [OathWCNetworkChoice]
    let methods: [OathWCMethodGroup]
    let supported: Bool
    let loadingAccounts: Bool
    let working: Bool
    let failed: Bool
    @Binding var walletID: String
    @Binding var selected: Set<String>
    @Binding var acknowledged: Bool
    let approve: () -> Void
    let reject: () -> Void
    let close: @MainActor () -> Void
    var unavailableMethods: Set<String> = []
    @Environment(\.oathLocalizer) private var strings

    private var selectedWallet: String { wallets.first { $0.id == walletID }?.name ?? strings.text(.wcWalletUnavailable) }
    private var canApprove: Bool {
        !working && !loadingAccounts && supported && identity.verification != .blocked &&
        (identity.verification != .unknown || acknowledged)
    }
    var body: some View {
        OathWCContent {
            VStack(spacing: 14) {
                OathDAppLogo(icons: identity.icons, size: 64)
                Text(strings.format(.wcConnectTo, identity.displayName)).oathFont(.title2, weight: .semibold)
                Text(identity.domain).oathFont(.subheadline).foregroundStyle(.secondary)
                    .environment(\.layoutDirection, .leftToRight)
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(24)
            NavigationLink {
                walletPage
            } label: {
                OathSettingsRow(title: selectedWallet, icon: "wallet.pass", subtitle: strings.text(.wcChooseWallet))
            }.buttonStyle(OathSettingsRowButtonStyle()).disabled(working)
                .accessibilityIdentifier("walletconnect.wallet")
            NavigationLink {
                networkPage
            } label: {
                OathSettingsRow(title: strings.text(.wcNetworks), icon: "globe",
                    subtitle: networks.filter { selected.contains($0.id) }.map(\.name).joined(separator: " · "),
                    isWorking: loadingAccounts)
            }.buttonStyle(OathSettingsRowButtonStyle()).disabled(working || loadingAccounts)
                .accessibilityIdentifier("walletconnect.networks")
            OathSettingsSectionRule()
            OathSettingsFooter {
                Text(strings.text(.wcConnectionSummary))
            }
            NavigationLink {
                OathWCAccessPage(identity: identity, methods: methods, close: close)
            } label: {
                OathSettingsRow(title: strings.text(.wcReviewPermissions), icon: "hand.raised")
            }.buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.permissions")
            NavigationLink {
                OathWCIdentityPage(identity: identity, close: close)
            } label: {
                OathSettingsRow(title: strings.text(.wcWebsiteDetails), icon: "globe",
                    value: strings.text(identity.verification == .matched ? .wcDomainMatches : .wcDomainUnknown))
            }.buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.identity")
            if identity.verification == .blocked || (!supported && !loadingAccounts) {
                OathSettingsFooter {
                    Label(strings.text(identity.verification == .blocked ? .scannerWCBlocked : .wcUnsupportedTitle), systemImage: "exclamationmark.shield")
                        .foregroundStyle(.red)
                    Text(strings.text(identity.verification == .blocked ? .scannerWCBlockedDetail : .wcUnsupportedDetail))
                }.accessibilityIdentifier("walletconnect.blocked")
                if identity.verification != .blocked {
                    ForEach(["wallet_addEthereumChain", "wallet_sendCalls"].filter { unavailableMethods.contains($0) }, id: \.self) { method in
                        NavigationLink {
                            OathWCUnavailableMethodPage(method: method, close: close)
                        } label: {
                            OathSettingsRow(title: strings.text(method == "wallet_sendCalls" ? .wcBatchRequest : .wcNetworkRequest), icon: "info.circle")
                        }.buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.unavailable." + method)
                    }
                }
            } else if identity.verification == .unknown {
                OathSettingsFooter { Text(strings.text(.scannerWCUnverifiedDetail)) }
                Toggle(strings.text(.scannerWCAcknowledge), isOn: $acknowledged)
                    .oathFont(.body).tint(OathOnboardingColors.blue).padding(.horizontal, 20).padding(.bottom, 20)
                    .disabled(working).accessibilityIdentifier("walletconnect.acknowledge")
            }
            if failed { OathSettingsFooter { Text(strings.text(.scannerWCError)).foregroundStyle(.red) } }
        }
        .oathBottomActions {
            OathWCFooter {
                OathActionButton(title: strings.text(.scannerConnect), foreground: canApprove ? nil : .secondary, isWorking: working, action: approve)
                    .disabled(!canApprove).accessibilityIdentifier("walletconnect.approve")
                OathButton(strings.text(.scannerWCReject), role: .destructive, action: reject)
                    .oathFont(.body).foregroundStyle(.red).padding(.vertical, 8).disabled(working)
                    .accessibilityIdentifier("walletconnect.reject")
            }
        }
    }
    private var walletPage: some View {
        OathWCContent {
            OathSettingsFooter { Text(strings.text(.wcChooseWalletDetail)) }
            ForEach(wallets) { wallet in
                OathButton { walletID = wallet.id } label: {
                    OathSettingsRow(title: wallet.name, icon: "wallet.pass", accessory: .selection(walletID == wallet.id))
                }.buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.chooseWallet." + wallet.id)
            }
        }.navigationTitle(strings.text(.wcChooseWallet)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }
            
    }
    private var networkPage: some View {
        OathWCContent {
            OathSettingsFooter { Text(strings.text(.wcChooseNetworksDetail)) }
            ForEach(networks) { network in
                OathButton {
                    guard !network.required, network.address != nil else { return }
                    if selected.contains(network.id) { selected.remove(network.id) } else { selected.insert(network.id) }
                } label: {
                    OathSettingsRow(title: network.name,
                        value: network.required ? strings.text(.scannerWCRequired) : nil,
                        accessory: .selection(selected.contains(network.id)),
                        subtitle: network.address.map { $0.count > 22 ? String($0.prefix(9)) + "…" + String($0.suffix(7)) : $0 } ?? strings.text(.wcWalletUnavailable),
                        networkLogo: network.logo)
                }.buttonStyle(OathSettingsRowButtonStyle()).disabled(network.required || network.address == nil)
                    .accessibilityIdentifier("walletconnect.network." + network.id)
            }
            OathSettingsFooter { Text(strings.text(.wcNetworkAccessDetail)) }
        }.navigationTitle(strings.text(.wcNetworks)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }
            
    }
}

struct OathWCContent<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.vertical, 16).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }.background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
            .oathNativeLocalization()
    }
}

struct OathWCFooter<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: OathActionMetrics.spacing, content: content)
    }
}

struct OathWCDAppHeader: View {
    let identity: OathWCIdentity
    var body: some View {
        HStack(spacing: 14) {
            OathDAppLogo(icons: identity.icons, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(identity.displayName).oathFont(.body, weight: .semibold)
                Text(identity.domain).oathFont(.subheadline).foregroundStyle(.secondary)
                    .environment(\.layoutDirection, .leftToRight)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(20)
    }
}

struct OathWCAccessPage: View {
    let identity: OathWCIdentity
    let methods: [OathWCMethodGroup]
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathWCContent {
            OathWCDAppHeader(identity: identity)
            section(.wcPublicInformation, .scannerWCAccountsPermission, "eye")
            section(.wcRequestsYouApprove, .wcConnectionSummary, "signature")
            section(.wcPrivateInformation, .wcPrivateInformationDetail, "lock.shield")
            OathSettingsSectionRule()
            NavigationLink { OathWCMethodsPage(identity: identity, methods: methods, close: close) } label: {
                OathSettingsRow(title: strings.text(.wcMethods), icon: "list.bullet")
            }.buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.methods")
            NavigationLink { OathWCIdentityPage(identity: identity, close: close) } label: {
                OathSettingsRow(title: strings.text(.wcWebsiteDetails), icon: "globe")
            }.buttonStyle(OathSettingsRowButtonStyle())
        }.navigationTitle(strings.text(.scannerWCPermissions)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }
            
    }
    private func section(_ title: OathStringKey, _ detail: OathStringKey, _ icon: String) -> some View {
        VStack(spacing: 0) {
            OathSettingsRow(title: strings.text(title), icon: icon, accessory: .none)
            OathSettingsFooter { Text(strings.text(detail)) }
        }
    }
}

struct OathWCMethodsPage: View {
    let identity: OathWCIdentity
    let methods: [OathWCMethodGroup]
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathWCContent {
            OathWCDAppHeader(identity: identity)
            OathSettingsFooter { Text(strings.text(.wcMethodsDetail)) }
            ForEach(methods) { group in
                OathSettingsRow(title: group.id, icon: "globe", accessory: .none)
                ForEach(group.methods, id: \.self) { method in
                    Text(method).oathFont(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 10)
                        .environment(\.layoutDirection, .leftToRight)
                }
                if !group.events.isEmpty {
                    OathSettingsFooter { Text(strings.text(.wcEvents) + ": " + group.events.joined(separator: ", ")) }
                }
                OathSettingsSectionRule()
            }
        }.navigationTitle(strings.text(.wcMethods)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }
            
    }
}

struct OathWCIdentityPage: View {
    let identity: OathWCIdentity
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathWCContent {
            OathWCDAppHeader(identity: identity)
            OathWCValue(title: strings.text(.wcWebsiteDetails), value: identity.domain, leftToRight: true)
            OathWCValue(title: strings.text(.wcRequestOrigin), value: identity.origin.flatMap(OathWalletConnectPolicy.safeHost) ?? strings.text(.wcDomainUnknown), leftToRight: true)
            OathWCValue(title: strings.text(.wcDomainCheck), value: strings.text(identity.verification == .matched ? .wcDomainMatches : identity.verification == .blocked ? .scannerWCBlocked : .wcDomainUnknown))
            OathSettingsSectionRule()
            OathSettingsFooter { Text(strings.text(.wcDomainCheckDetail)) }
        }.navigationTitle(strings.text(.wcWebsiteDetails)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { OathCloseButton(action: close) } }
            
    }
}

struct OathWCValue: View {
    let title: String
    let value: String
    var leftToRight = false
    @Environment(\.layoutDirection) private var layoutDirection
    var body: some View {
        Group {
        if leftToRight, value.count >= 40, !value.contains(" ") {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).foregroundStyle(.secondary)
                OathAddressText(address: value, identifier: "walletconnect.exactValue", centered: false)
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else { ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(title).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 0)
                valueText.multilineTextAlignment(.trailing).fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).foregroundStyle(.secondary)
                valueText.fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        } }
        }.oathFont(.body).padding(.horizontal, 20).padding(.vertical, 14)
    }
    private var valueText: some View {
        Text(value).textSelection(.enabled).environment(\.layoutDirection, leftToRight ? .leftToRight : layoutDirection)
    }
}
