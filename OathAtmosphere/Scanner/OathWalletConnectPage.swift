import OathAnkr
import OathBitcoin
import SwiftUI
import SafariServices
@preconcurrency import WalletConnectSign
import OathDiagnostics

/// Lives in Settings' existing NavigationStack. The SDK supplies all sessions;
/// the page never synthesizes connections or assumes the currently selected wallet.
struct OathWalletConnectPage: View {
    let session: OathWalletSession
    var walletID: String? = nil
    private var visibleSessions: [Session] { service.sessions.filter { walletID == nil || service.walletID(for: $0.topic) == walletID } }
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @State private var service = OathWalletConnectService.shared
    @State private var scanner = false
    @State private var browser: OathDAppWebsite?

    var body: some View {
        Group {
            if !service.configured {
                OathEmptyStateScrollView {
                    OathEmptyState(strings.text(.scannerWCUnavailable), systemImage: "wifi.exclamationmark",
                                   description: strings.text(.scannerWCError))
                }
            } else if visibleSessions.isEmpty {
                OathEmptyStateScrollView {
                    OathEmptyState(title: strings.text(.scannerWCNoSessions), systemImage: "link",
                                  description: strings.text(.wcEmptyDetail)) {
                        OathButton(strings.text(.wcAddConnection)) { openScanner() }.oathNeutralControl()
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleSessions, id: \.topic) { item in
                            NavigationLink {
                                OathWalletConnectDetail(topic: item.topic, session: session) {
                                    browser = .init(url: $0)
                                }
                            } label: {
                                OathWalletConnectRow(item: item,
                                    connectedAt: service.connections.connectedAt(item.topic),
                                    revoked: service.connections.isRevoked(item.topic))
                            }
                            .buttonStyle(OathSettingsRowButtonStyle())
                            .accessibilityIdentifier("walletconnect.session")
                        }
                    }.padding(.vertical, 12).frame(maxWidth: 700).frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .navigationTitle(strings.text(.walletConnect))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OathButton { openScanner() } label: { Image(systemName: "plus") }
                    .oathNeutralControl().accessibilityLabel(strings.text(.wcAddConnection))
                    .accessibilityIdentifier("walletconnect.add")
                    .disabled(!service.configured || !session.isUnlocked || service.sessions.count >= 32)
            }
        }
        .task(id: scenePhase == .active && session.isUnlocked) {
            guard scenePhase == .active, session.isUnlocked else { return }
            service.configure(session: session); service.refreshSessions(); service.resumeRequests()
            await service.retryDisconnections()
        }
        .oathScannerCover(isPresented: $scanner) {
            OathScanner(strings: strings, onPayload: { _ in }, onFailure: { _ in scanner = false },
                        onClose: { scanner = false }, title: .walletConnect,
                        identifier: "walletconnect.scanner", context: .walletConnect)
                .environment(\.oathScanSession, session)
        }
        .fullScreenCover(item: $browser) { website in
            OathDAppBrowser(url: website.url) { browser = nil }.ignoresSafeArea()
        }
        .onChange(of: session.isUnlocked) { _, unlocked in
            if !unlocked { scanner = false; browser = nil }
        }
        .oathNativeLocalization()
    }
    private func openScanner() {
        guard service.configured, session.isUnlocked, !session.changingWallet, !session.resetting,
              service.sessions.count < 32 else { return }
        scanner = true
    }

}

struct OathWalletConnectRow: View {
    let item: Session
    let connectedAt: Date?
    let revoked: Bool
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        OathListRow {
            OathDAppLogo(icons: item.peer.icons)
        } content: {
            VStack(alignment: .leading, spacing: 5) {
                Text(OathWalletConnectPolicy.displayName(item.peer.name)).oathFont(.body).foregroundStyle(.primary).lineLimit(1)
                Text(OathWalletConnectPolicy.safeHost(item.peer.url) ?? "—")
                    .oathFont(.subheadline).foregroundStyle(.secondary).lineLimit(1).environment(\.layoutDirection, .leftToRight)
                if revoked {
                    Text(strings.text(.wcDisconnectPending)).oathFont(.caption).foregroundStyle(.secondary)
                } else if let connectedAt {
                    Text(connectedAt, style: .relative).oathFont(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel(strings.text(.wcConnectedFor) + ": " + connectedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(strings.language.locale)))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } accessory: {
            Image(systemName: "chevron.forward").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}

private struct OathWalletConnectDetail: View {
    let topic: String
    let session: OathWalletSession
    let openWebsite: (URL) -> Void
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dismiss) private var dismiss
    @State private var service = OathWalletConnectService.shared
    @State private var confirmDisconnect = false
    private var item: Session? { service.sessions.first { $0.topic == topic } }
    private var revoked: Bool { service.connections.isRevoked(topic) }

    var body: some View {
        Group {
            if let item { details(item) }
            else {
                OathEmptyStateScrollView {
                    OathEmptyState(strings.text(.wcDisconnected), systemImage: "link",
                                   description: strings.text(.wcDisconnectedDetail))
                }
            }
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .navigationTitle(strings.text(.wcConnectionDetails)).navigationBarTitleDisplayMode(.inline)
        .alert(strings.text(.scannerWCDisconnect), isPresented: $confirmDisconnect) {
            OathButton(strings.text(.scannerWCDisconnect), role: .destructive) {
                Task { _ = await service.disconnect(topic) }
            }.accessibilityIdentifier("walletconnect.disconnect.confirm")
            OathButton(strings.text(.cancel), role: .cancel) { }
        } message: { Text(strings.text(.wcDisconnectDetail)) }
        .oathNativeLocalization()
    }
    private func details(_ item: Session) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    OathDAppLogo(icons: item.peer.icons, size: 72)
                    Text(OathWalletConnectPolicy.displayName(item.peer.name)).oathFont(.title2, weight: .semibold)
                    Text(OathWalletConnectPolicy.safeHost(item.peer.url) ?? "—")
                        .oathFont(.subheadline).foregroundStyle(.secondary).environment(\.layoutDirection, .leftToRight)
                    if !item.peer.description.isEmpty {
                        Text(OathWalletConnectPolicy.displayText(item.peer.description))
                            .oathFont(.subheadline).foregroundStyle(.secondary)
                    }
                }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(24)
                if let url = OathWalletConnectPolicy.website(item.peer.url) {
                    OathButton { openWebsite(url) } label: {
                        OathSettingsRow(title: strings.text(.wcOpenWebsite), icon: "safari")
                    }.buttonStyle(OathSettingsRowButtonStyle()).accessibilityIdentifier("walletconnect.openWebsite")
                }
                OathSettingsSectionRule()
                information(.wcStatus, value: strings.text(revoked ? .wcDisconnectPending : .scannerWCConnected))
                let wallet = session.wallets.first { $0.id == service.walletID(for: topic) }
                information(.scannerWCAccount, value: wallet.map { session.walletName($0, strings: strings) } ?? strings.text(.wcWalletUnavailable))
                if let date = service.connections.connectedAt(topic) {
                    information(.wcConnectedSince, value: date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(strings.language.locale)))
                    HStack {
                        Text(strings.text(.wcConnectedFor)).foregroundStyle(.secondary)
                        Spacer(minLength: 16)
                        Text(date, style: .relative).multilineTextAlignment(.trailing)
                    }.oathFont(.body).padding(.horizontal, 20).padding(.vertical, 16)
                } else { information(.wcConnectedSince, value: strings.text(.wcDateUnknown)) }
                information(.wcExpires, value: item.expiryDate.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(strings.language.locale)))
                OathSettingsSectionRule()
                NavigationLink {
                    OathWalletConnectSessionNetworks(topic: topic)
                } label: {
                    OathSettingsRow(title: strings.text(.wcNetworks), icon: "globe")
                }.buttonStyle(OathSettingsRowButtonStyle())
                    .accessibilityIdentifier("walletconnect.session.networks")
                OathSettingsSectionRule()
                sectionTitle(.scannerWCPermissions)
                Text(strings.text(.scannerWCDetail)).oathFont(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 12)
                // Keep permissions tied to their namespace rather than implying
                // that a method is available on every approved network.
                ForEach(item.namespaces.keys.sorted(), id: \.self) { namespace in
                    if let value = item.namespaces[namespace] {
                        information(.wcNamespace, value: OathWalletConnectPolicy.displayName(namespace))
                        information(.wcMethods, value: value.methods.sorted().map { OathWalletConnectPolicy.displayName($0) }.joined(separator: "\n"))
                        information(.wcEvents, value: value.events.sorted().map { OathWalletConnectPolicy.displayName($0) }.joined(separator: "\n"))
                    }
                }
                OathSettingsSectionRule()
                OathButton(role: .destructive) {
                    if revoked { Task { if await service.disconnect(topic) { dismiss() } } }
                    else { confirmDisconnect = true }
                } label: {
                    OathSettingsRow(title: strings.text(revoked ? .tryAgain : .scannerWCDisconnect), icon: "xmark.circle",
                                    accessory: .none, isWorking: service.disconnecting.contains(topic), color: .red)
                }.buttonStyle(OathSettingsRowButtonStyle()).disabled(service.disconnecting.contains(topic))
                    .accessibilityIdentifier("walletconnect.disconnect")
                if revoked {
                    Text(strings.text(.wcDisconnectRetryDetail)).oathFont(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
            }.padding(.bottom, 20).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
    }
    private func information(_ title: OathStringKey, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(strings.text(title)).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 0)
                Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing).fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(strings.text(title)).foregroundStyle(.secondary)
                Text(value.isEmpty ? "—" : value).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.oathFont(.body).padding(.horizontal, 20).padding(.vertical, 16)
    }
    private func sectionTitle(_ title: OathStringKey) -> some View {
        Text(strings.text(title)).oathFont(.headline).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

private struct OathWalletConnectSessionNetworks: View {
    let topic: String
    @Environment(\.oathLocalizer) private var strings
    @State private var service = OathWalletConnectService.shared
    private var item: Session? { service.sessions.first { $0.topic == topic } }

    var body: some View {
        Group {
            if let item {
                OathWCContent {
                    ForEach(Array(Set(item.accounts.map { $0.blockchain.absoluteString })).sorted(), id: \.self) { blockchain in
                        let solana = SolanaSendNetwork(walletConnectChain: blockchain)
                        let chain = OathWalletConnectService.chain(for: blockchain)
                        OathSettingsRow(
                            title: XrplSendNetwork(walletConnectChain:blockchain)?.walletConnectName ?? StellarSendNetwork(walletConnectChain:blockchain)?.walletConnectName ?? NearSendNetwork(walletConnectChain:blockchain)?.walletConnectName ?? SuiSendNetwork(walletConnectChain:blockchain)?.walletConnectName ?? PolkadotConnectNetwork(chain: blockchain)?.name ?? BitcoinConnectNetwork(chain: blockchain)?.name ?? solana?.walletConnectName ?? TronSendNetwork(walletConnectChain: blockchain)?.walletConnectName ?? TonSendNetwork(walletConnectChain: blockchain)?.walletConnectName ?? chain?.name ?? OathWalletConnectPolicy.displayName(blockchain),
                            icon: chain == nil ? "globe" : nil,
                            accessory: .none,
                            networkLogo: chain.map { "network-" + $0.id })
                            .accessibilityIdentifier("walletconnect.session.network." + blockchain)
                    }
                }
            } else {
                OathEmptyStateScrollView {
                    OathEmptyState(strings.text(.wcDisconnected), systemImage: "link",
                                   description: strings.text(.wcDisconnectedDetail))
                }
            }
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .navigationTitle(strings.text(.wcNetworks)).navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("walletconnect.session.networks.page")
        .oathNativeLocalization()
    }
}

private struct OathDAppWebsite: Identifiable {
    let id = UUID()
    let url: URL
}
/// Safari owns the browser UI, cookies and navigation. WalletConnect approval
/// is presented above this controller without discarding the dApp's page state.
private struct OathDAppBrowser: UIViewControllerRepresentable {
    let url: URL
    let onClose: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onClose: onClose) }
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        controller.dismissButtonStyle = .done
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) { }
    @MainActor final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onClose: () -> Void
        let operation = UUID()
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            Task { @MainActor in onClose() }
        }
        nonisolated func safariViewController(_ controller: SFSafariViewController, didCompleteInitialLoad success: Bool) {
            if !success {
                Task { @MainActor in
                    OathDiagnostics.$operationID.withValue(operation) {
                        OathDiagnostics.record(DiagnosticFailure("DApp browser initial load failed"), component: "walletconnect", operation: "browser_load")
                    }
                }
            }
        }
    }
}
