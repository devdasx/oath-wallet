import Observation
import SwiftUI
import Testing
import UIKit
@testable import Aperture

/// Real Review UI with a local fee and a suspended authorization callback.
/// No account secrets, biometric prompts, signing, broadcasting, or screenshots.
@MainActor
@Suite(.serialized)
struct NativeSendReviewRecipientTests {
    @Test(arguments: NativeListTestLayout.allCases)
    func confirmKeepsRecipientVisibleWhileAuthorizingAndAfterCancellation(layout: NativeListTestLayout) async throws {
        let database = try WalletDatabase.temporary()
        let preferences = SendNetworkFeePreferenceRepository(database: database)
        // A valid EVM custom fee needs no live account or UTXO lookup. A
        // Bitcoin total budget correctly requires exact inputs before Confirm.
        let custom = SendNetworkFeeCustomValue(model: .evmLegacy, primaryValue: "42000000000", secondaryValue: nil,
                                               totalBudgetAtomic: "882000000000000")
        try await preferences.saveCustom(custom, for: "eth")
        let network = try #require(AssetNetworkSelectorOption.allSupported.first { $0.blockchain == .ethereum })
        let asset = try SendEntryTestFixtures.nativeChoice(for: network)
        let recipient = "0x0000000000000000000000000000000000000043"
        let draft = SendEntryTestFixtures.draft(asset: asset, recipient: recipient, amount: "0.1")
            .replacingFeePolicy(.custom(custom))
        let model = ReviewRecipientTestState()
        let host = try NativeListTestHost(layout: layout) {
            ReviewRecipientTestView(database: database, preferences: preferences, draft: draft, model: model)
        }
        defer { host.close() }
        let list = try await host.list()
        let path = IndexPath(item: 0, section: 1)
        let cell = try await host.cell(at: path, in: list)
        try await assertRecipient(recipient, in: cell)
        let confirmLabel = WalletAppLanguage.localizedBundle(for: layout.direction == .rightToLeft ? "ar" : "en")
            .localizedString(forKey: "send.review.slide_action", value: nil, table: nil)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            host.accessibilityAction(label: confirmLabel, in: host.rootView)?
                .accessibilityTraits.contains(.notEnabled) == false
        }
        let confirm = try #require(host.accessibilityAction(label: confirmLabel, in: host.rootView))
        #expect(confirm.accessibilityActivate())
        try await SendEntryUIProbe.wait(in: host.rootView) {
            model.isAuthorizing && host.accessibilityAction(label: confirmLabel, in: host.rootView)?
                .accessibilityTraits.contains(.notEnabled) == true
        }
        #expect(model.submitted.count == 1)
        #expect(model.submitted.first?.recipient == recipient)
        #expect(model.submitted.first?.preparedNetworkFee?.primaryValue == "42000000000")
        try await assertRecipient(recipient, in: try await host.cell(at: path, in: list))
        for phase in [ScenePhase.inactive, .background, .active] {
            model.scenePhase = phase
            model.redactionReasons = phase == .active ? [] : .privacy
            await Task.yield()
            host.rootView.layoutIfNeeded()
            try await assertRecipient(recipient, in: try await host.cell(at: path, in: list))
        }
        let navigation = try #require(host.navigationController)
        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in
            navigation.present(cover, animated: false) { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            cover.dismiss(animated: false) { continuation.resume() }
        }
        model.isAuthorizing = false
        try await SendEntryUIProbe.wait(in: host.rootView) {
            host.accessibilityAction(label: confirmLabel, in: host.rootView)?
                .accessibilityTraits.contains(.notEnabled) == false
        }
        try await assertRecipient(recipient, in: try await host.cell(at: path, in: list))
    }

    private func assertRecipient(_ recipient: String, in root: UIView) async throws {
        try await SendEntryUIProbe.wait(in: root) {
            SendEntryUIProbe.views(UITextView.self, in: root).contains {
                $0.text == recipient && !$0.isHidden && $0.alpha > 0
                    && $0.bounds.width > 0 && $0.bounds.height > 0
            }
        }
        let text = try #require(SendEntryUIProbe.views(UITextView.self, in: root).first { $0.text == recipient })
        #expect(text.accessibilityLabel == recipient)
        #expect(text.contentOffset.y <= 0)
        #expect(text.textLayoutManager?.textViewportLayoutController.viewportRange != nil)
        #expect(text.isSelectable)
        // UIKit may represent the same label color as RGB or monochrome.
        let actualColor = try #require(text.textColor)
            .resolvedColor(with: text.traitCollection)
        let expectedColor = UIColor.label.resolvedColor(with: text.traitCollection)
        var actual = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        var expected = actual
        #expect(actualColor.getRed(&actual.0, green: &actual.1, blue: &actual.2, alpha: &actual.3))
        #expect(expectedColor.getRed(&expected.0, green: &expected.1, blue: &expected.2, alpha: &expected.3))
        for (lhs, rhs) in zip([actual.0, actual.1, actual.2, actual.3],
                              [expected.0, expected.1, expected.2, expected.3]) {
            #expect(abs(lhs - rhs) < 0.000_001)
        }
        #expect(text.bounds.height >= text.sizeThatFits(CGSize(width: text.bounds.width, height: 10_000)).height - 1)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func identityDetailSheetsFollowPrivacySettingAcrossLifecycle(layout: NativeListTestLayout) async throws {
        let value = String(repeating: "0123456789abcdef", count: 4)
        for history in [false, true] {
            let state = ReviewRecipientTestState()
            let host = try NativeListTestHost(layout: layout) {
                Color.clear.sheet(isPresented: .constant(true)) {
                    Group {
                        if history {
                            WalletTransactionIdentityDetailSheet(detail: .init(
                                kind: .transactionHash, value: value, networkID: "bitcoin"
                            ))
                        } else {
                            SendTransactionIdentityDetailSheet(detail: .init(
                                kind: .transactionID, value: value, networkID: "bitcoin"
                            ))
                        }
                    }
                    .environment(\.walletPrivacyShieldEnabled, state.privacyEnabled)
                    .environment(\.scenePhase, state.scenePhase)
                    .redacted(reason: state.redactionReasons)
                }
            }
            defer { host.close() }
            let window = try #require(host.rootView.window)
            try await assertRecipient(value, in: window)
            state.scenePhase = .inactive
            state.redactionReasons = .privacy
            await Task.yield()
            try await assertRecipient(value, in: window)
            state.privacyEnabled = true
            try await SendEntryUIProbe.wait(in: window) {
                SendEntryUIProbe.views(UITextView.self, in: window).contains {
                    $0.text == value && $0.isHidden && !$0.isSelectable && !$0.isAccessibilityElement
                }
            }
            // Switching the setting off restores the same value even while
            // the system privacy reason remains in the environment.
            state.privacyEnabled = false
            try await assertRecipient(value, in: window)
            state.scenePhase = .active
            state.redactionReasons = []
            try await assertRecipient(value, in: window)
        }
    }
}

@MainActor
@Observable
private final class ReviewRecipientTestState {
    var isAuthorizing = false
    var scenePhase = ScenePhase.active
    var redactionReasons: RedactionReasons = []
    var privacyEnabled = false
    var submitted: [SendDraft] = []
}

private struct ReviewRecipientTestView: View {
    let database: WalletDatabase
    let preferences: SendNetworkFeePreferenceRepository
    let draft: SendDraft
    let model: ReviewRecipientTestState

    var body: some View {
        NavigationStack {
            SendReviewScreen(database: database, feePreferences: preferences, draft: draft,
                             nativeUnitUSDPrice: 60_000, isAuthorizing: model.isAuthorizing) {
                model.submitted.append($0)
                model.isAuthorizing = true
            }
        }
        .environment(\.scenePhase, model.scenePhase)
        .environment(\.walletPrivacyShieldEnabled, false)
        .redacted(reason: model.redactionReasons)
    }
}
