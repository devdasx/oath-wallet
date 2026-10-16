#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import OathDiagnostics

/// Live simulator relay harness. Uses the real encrypted vault, passcode UI,
/// session service, SDK and approval views. The only imported key is a public
/// test vector; no user wallet or production installation is accessed.
struct OathWalletConnectRelayFixture: View {
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "oath.wcRelayFixture") &&
        UserDefaults.standard.string(forKey: "oath.walletTestScope").flatMap(UUID.init(uuidString:)) != nil
    }
    let session: OathWalletSession
    @State private var ready = false
    @State private var failed = false
    @State private var stage = "loading"
    @State private var failureType = ""
    @State private var request: OathWalletLinkInbox.Entry?
    @State private var service = OathWalletConnectService.shared
    private struct Fixture: Decodable { let uri: String }
    var body: some View {
        NavigationStack {
            if failed { Text("Relay fixture setup failed: \(stage) / \(failureType)").accessibilityIdentifier("wc.relay.failed") }
            else if ready {
                VStack {
                    Text("Isolated live relay check").accessibilityIdentifier("wc.relay.ready")
                    Button("Open connection") {
                        request = .init(route: .connections, expires: .distantFuture)
                    }.accessibilityIdentifier("wc.relay.open")
                    NavigationLink("Manage connections") {
                        OathWalletConnectPage(session: session, walletID: session.wallets.first?.id)
                    }.accessibilityIdentifier("wc.relay.manage")
                }
            } else { ProgressView() }
        }.task {
            do {
                // This root replaces WalletRoot, which normally owns load().
                await session.load()
                stage = "vault"
                if try await session.vault.exists() { await session.unlock([1,2,3,4,5,6]) }
                else {
                    try await session.vault.create(digits: [1,2,3,4,5,6], importing: nil,
                        privateKey: .init(bytes: Data(repeating: 1, count: 32), networks: [.ethereum, .arbitrum]))
                    stage = "home"
                    await session.finishedSetup(requiresCustomization: false)
                }
                guard session.isUnlocked else { throw OathWalletError.locked }
                stage = "pairing-file"
                let file = URL.documentsDirectory.appendingPathComponent("walletconnect-relay-fixture.json")
                let data = try Data(contentsOf: file)
                guard data.count < 4096 else { throw OathWalletConnectService.ConfigurationFailure.invalid }
                let fixture = try JSONDecoder().decode(Fixture.self, from: data)
                try FileManager.default.removeItem(at: file)
                service.configure(session: session)
                stage = "pairing"
                ready = true
                request = .init(route: .pair(fixture.uri), expires: .distantFuture)
            } catch {
                OathDiagnostics.record(error, component: "walletconnect_test", operation: "relay_fixture_setup")
                failureType = String(describing: type(of: error))
                if let installationError = error as? OathInstallationSecurityError {
                    // This closed enum carries no wallet data; display only a
                    // fixed category or numeric OSStatus in the test harness.
                    switch installationError {
                    case .keychain(let status): failureType = "keychain-\(status)"
                    case .invalidKey: failureType = "invalid-installation-key"
                    case .invalidRecord: failureType = "invalid-installation-record"
                    case .unsafePath: failureType = "unsafe-installation-path"
                    }
                }
                failed = true
            }
        }.sheet(item: $request, onDismiss: {
            service.presentationDidDismiss()
            if service.needsPresentation { request = .init(route: .connections, expires: .distantFuture) }
        }) { item in
            OathWalletConnectSheet(uri: item.uri, session: session)
        }.onChange(of: service.needsPresentation) { _, needed in
            if needed, request == nil { request = .init(route: .connections, expires: .distantFuture) }
        }
    }
}
#endif
