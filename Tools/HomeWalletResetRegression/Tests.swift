import XCTest
import SwiftUI
import OathNativeRefresh

enum OathSurfaceColors { static var groupedCanvas: UIColor { .systemBackground } }

@MainActor @Observable private final class WalletFixture {
    var id = UUID()
    var balance = "$120.00"
    var sheet: FixtureSheet?
    var customizing = false
    var pendingCustomization = false
    var backupPending = false
    var backupsPresented = 0
    var beforeBackup: (() -> Void)?
}

private enum FixtureSheet: String, Identifiable {
    case wallets, backup
    var id: String { rawValue }
}

private struct BackupCandidate: Equatable {
    enum Kind { case backup }
    let kind = Kind.backup
    let walletID: UUID
}

private struct FixtureStrings {
    struct Language { let isRightToLeft: Bool }
    let language: Language
}

private struct HomeFixture: View {
    @Bindable var model: WalletFixture
    let strings: FixtureStrings
    private var profile: WalletFixture? { model }
    private var claimedBackupOffers: [UUID: String] { [model.id: "synthetic-offer"] }
    private var nextSecurityNotice: BackupCandidate? {
        model.backupPending && model.sheet == nil && !model.customizing && !model.pendingCustomization
            ? BackupCandidate(walletID: model.id) : nil
    }

    private func presentNextSecurityNotice(afterHomeAppearance: Bool = false) {
        guard afterHomeAppearance, nextSecurityNotice != nil else { return }
        model.beforeBackup?()
        model.backupsPresented += 1
        model.backupPending = false
        model.sheet = .backup
    }

    var body: some View {
        TabView {
            NavigationStack {
                NativeRefreshScroll(identifier: "home.scroll", tint: .white,
                    indicator: .progressRing, timing: .brief, refreshIdentity: profile?.id.uuidString,
                    action: {}, onFailure: {}, onScroll: { _ in }) {
                    OathHeaderScrollContent(viewportHeight: 800) {
                        VStack {
                            Text("Total Balance")
                            Text(model.balance).font(.system(size: 58, weight: .semibold))
                                .accessibilityIdentifier("fixture.balance")
                        }.foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 320)
                    } content: {
                        Text("Assets").frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                    ForEach(0..<80) { index in
                        HStack { Text("Asset \(index)"); Spacer(); Text(model.balance) }
                            .padding(20).frame(height: 78).background(.background)
                    }
                }
                // PRODUCTION_SCROLL_IDENTITY
                .modifier(OathHeaderScrollBackground { Color.blue })
                // PRODUCTION_BACKUP_APPEARANCE
                .navigationTitle("Wallet")
                .navigationBarTitleDisplayMode(.inline)
            }.tabItem { Label("Home", systemImage: "wallet.bifold") }
        }
        .sheet(item: $model.sheet, onDismiss: {
            if model.pendingCustomization {
                model.pendingCustomization = false
                model.customizing = true
            }
        }) { sheet in
            Text(sheet == .wallets ? "Wallets" : "Back up your wallet")
                .presentationDetents([.medium])
        }
        .fullScreenCover(isPresented: $model.customizing) { Text("Customize Wallet") }
        .environment(\.layoutDirection, strings.language.isRightToLeft ? .rightToLeft : .leftToRight)
        .environment(\.scenePhase, .active)
    }
}

@MainActor final class HomeWalletResetTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testNewWalletStartsAtBalanceBeforeBackupLTR() async throws { try await check(rtl: false) }
    func testNewWalletStartsAtBalanceBeforeBackupRTL() async throws { try await check(rtl: true) }

    private func check(rtl: Bool) async throws {
        let model = WalletFixture()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: HomeFixture(model: model,
            strings: .init(language: .init(isRightToLeft: rtl))))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await waitUntil { self.scroll(in: host.view)?.contentSize.height ?? 0 > 2000 }
        let original = try XCTUnwrap(scroll(in: host.view))
        original.setContentOffset(CGPoint(x: 0, y: 1400), animated: false)
        try await settle()
        XCTAssertGreaterThan(original.contentOffset.y, 1000)
        model.balance = "$121.00"
        try await settle()
        XCTAssertTrue(scroll(in: host.view) === original, "Same-wallet update retains the native list")
        XCTAssertGreaterThan(original.contentOffset.y, 1000, "Price changes must not jump Home to the top")

        model.sheet = .wallets
        try await waitUntil { host.presentedViewController != nil }
        try await settle()
        model.id = UUID()
        model.balance = "$0.00"
        model.backupPending = true
        model.pendingCustomization = true
        model.sheet = nil
        try await waitUntil { model.customizing }
        try await settle()
        XCTAssertEqual(model.backupsPresented, 0, "Backup must wait for customization")

        model.beforeBackup = {
            let current = self.scroll(in: host.view)
            XCTAssertNotNil(current)
            XCTAssertEqual((current?.contentOffset.y ?? 1000) + (current?.adjustedContentInset.top ?? 0),
                0, accuracy: 1, "The balance must already be visible when backup is requested")
            XCTAssertEqual(model.balance, "$0.00")
            XCTAssertNotNil(current?.window, "Home is attached before backup presentation")
        }
        model.customizing = false
        try await waitUntil { model.backupsPresented == 1 }
        try await settle()
        model.sheet = nil
        try await waitUntil { host.presentedViewController == nil }
        try await settle()
        let current = try XCTUnwrap(scroll(in: host.view))
        XCTAssertEqual(current.contentOffset.y + current.adjustedContentInset.top, 0, accuracy: 1)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        attachment.name = "new-wallet-home-" + (rtl ? "RTL" : "LTR")
        attachment.lifetime = .keepAlways
        add(attachment)

        current.setContentOffset(CGPoint(x: 0, y: 1000), animated: false)
        try await settle()
        model.id = UUID()
        model.balance = "$42.00"
        try await waitUntil {
            guard let switched = self.scroll(in: host.view) else { return false }
            return switched !== current && abs(switched.contentOffset.y + switched.adjustedContentInset.top) < 1
        }
        XCTAssertEqual(model.backupsPresented, 1, "Switching a wallet does not repeat a claimed offer")
    }

    private func scroll(in view: UIView) -> UIScrollView? {
        if view.accessibilityIdentifier == "home.scroll", let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scroll(in: $0) }.first
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(700)) }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for native Home/sheet transition")
        throw NSError(domain: "HomeWalletResetFixture", code: 1)
    }
}
