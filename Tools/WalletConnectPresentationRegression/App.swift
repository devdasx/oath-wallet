import SwiftUI
import Observation

@MainActor @Observable final class OathWalletSession {
    var isUnlocked = true
    var changingWallet = false
    var resetting = false
}
@MainActor @Observable final class OathWalletConnectService {
    static let shared = OathWalletConnectService()
    var needsPresentation = false
    var owner: UUID?
    var presentationOpen: Bool { owner != nil }
    var dismissed = 0
    func presentationDidOpen(_ id: UUID) -> Bool {
        guard owner == nil || owner == id else { return false }
        owner = id; return true
    }
    func presentationDidDismiss(_ id: UUID) {
        guard owner == id else { return }
        owner = nil; needsPresentation = false; dismissed += 1
    }
}
enum Route: Equatable { case connections, pair }
@MainActor @Observable final class OathWalletLinkInbox {
    static let shared = OathWalletLinkInbox()
    struct Entry {
        let id = UUID()
        let route: Route
        let expires: Date
        var uri: String? { route == .pair ? "synthetic" : nil }
    }
    var pending: Entry?
    var hasWalletConnectRequest: Bool { pending != nil }
    var dismissals = 0
    func take(walletConnectOnly: Bool) -> Entry? { defer { pending = nil }; return pending }
    func didDismiss() { dismissals += 1 }
}
@MainActor @Observable final class Probe {
    static let shared = Probe()
    let session = OathWalletSession()
    var base = false
    var nested = false
    var cover = false
    var topCover = false
    var locale = "en"
    var baseDismissals = 0
    var requestStarts = 0
    var closeRequest: (() -> Void)?
    var observedLocale = ""
    var checks = [String: Bool]()
}
struct OathWalletConnectSheet: View {
    let uri: String?
    let session: OathWalletSession?
    let presentationID: UUID
    var onDismiss: (() -> Void)?
    var onDismissDisabledChange: ((Bool) -> Void)? = nil
    @Environment(\.locale) var locale
    @State private var started = false
    var body: some View {
        @Bindable var probe = Probe.shared
        NavigationStack {
            Text("Incoming request")
                .toolbar { Button("Close") { onDismiss?() } }
        }
        .fullScreenCover(isPresented: $probe.topCover) { Text("Covered request") }
        .task {
            if !started { started = true; probe.requestStarts += 1 }
            probe.closeRequest = onDismiss
            onDismissDisabledChange?(false)
        }
        .onChange(of: locale.identifier, initial: true) { _, id in probe.observedLocale = id }
    }
}
@main struct PresentationProbe: App {
    var body: some Scene { WindowGroup { Root() } }
}
struct Root: View {
    @State var probe = Probe.shared
    var body: some View {
        Text("Home")
            .sheet(isPresented: $probe.base, onDismiss: { probe.baseDismissals += 1 }) {
                Text("Receive address")
                    .sheet(isPresented: $probe.nested) { Text("Address information") }
            }
            .fullScreenCover(isPresented: $probe.cover) { Text("Settings browser") }
            .oathWalletConnectPresentation(session: probe.session)
            .environment(\.locale, Locale(identifier: probe.locale))
            .task { await run() }
    }
    @MainActor func stack() -> [UIViewController] {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return [] }
        var rows = [top]
        while let next = top.presentedViewController { rows.append(next); top = next }
        return rows
    }
    @MainActor func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { try await Task.sleep(for: .milliseconds(450)); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "PresentationProbe", code: 1)
    }
    @MainActor func run() async {
        do {
            try await Task.sleep(for: .seconds(1))
            probe.base = true
            try await wait { stack().count == 2 }
            let underlying = stack()[1]
            let service = OathWalletConnectService.shared
            service.needsPresentation = true
            try await wait { stack().count == 3 && probe.closeRequest != nil }
            probe.checks["requestAboveExistingSheet"] = stack()[1] === underlying && service.presentationOpen
            let request = stack()[2]
            probe.topCover = true
            try await wait { stack().count == 4 }
            probe.checks["coverDoesNotDismissRequest"] = service.dismissed == 0
            probe.topCover = false
            try await wait { stack().count == 3 }
            probe.checks["requestSurvivesCover"] = stack()[2] === request && probe.requestStarts == 1
            probe.checks["dismissalPolicyReachesNativeSheet"] = !request.isModalInPresentation
            probe.locale = "fr"
            try await wait { probe.observedLocale == "fr" }
            probe.checks["environmentUpdatesWhilePresented"] = true
            probe.closeRequest?()
            try await wait { stack().count == 2 && !service.presentationOpen }
            probe.checks["underlyingSheetPreserved"] = stack()[1] === underlying && probe.baseDismissals == 0
            probe.checks["dismissalDeliveredOnce"] = service.dismissed == 1
            probe.nested = true
            try await wait { stack().count == 3 }
            let nested = stack()[2]
            service.needsPresentation = true
            try await wait { stack().count == 4 }
            probe.checks["requestAboveNestedSheets"] = stack()[2] === nested
            probe.closeRequest?()
            try await wait { stack().count == 3 && !service.presentationOpen }
            probe.nested = false
            try await wait { stack().count == 2 }
            probe.base = false
            try await wait { stack().count == 1 }
            probe.cover = true
            try await wait { stack().count == 2 }
            let browser = stack()[1]
            OathWalletLinkInbox.shared.pending = .init(route: .pair, expires: .distantFuture)
            try await wait { stack().count == 3 }
            probe.checks["pairAboveFullScreenCover"] = stack()[1] === browser && OathWalletLinkInbox.shared.pending == nil
            probe.closeRequest?()
            try await wait { stack().count == 2 && !service.presentationOpen }
            probe.checks["pairingInboxReleasedOnce"] = OathWalletLinkInbox.shared.dismissals == 1
            probe.cover = false
            try await wait { stack().count == 1 }
            probe.session.isUnlocked = false
            service.needsPresentation = true
            try await Task.sleep(for: .milliseconds(500))
            probe.checks["lockedWalletDefersRequest"] = stack().count == 1 && !service.presentationOpen
            probe.session.isUnlocked = true
            probe.base = true
            try await wait { stack().count == 3 }
            probe.checks["requestWaitsForPresentationTransition"] = service.presentationOpen && probe.requestStarts == 4
            probe.closeRequest?()
            try await wait { stack().count == 2 && !service.presentationOpen }
        } catch { probe.checks["completedWithoutTimeout"] = false }
        let output = URL.documentsDirectory.appending(path: "result.json")
        try? JSONEncoder().encode(probe.checks).write(to: output)
    }
}
