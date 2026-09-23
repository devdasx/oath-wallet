import SwiftUI
import GRDB
import Testing
@testable import Aperture

struct WalletSetupSheetCompletionTests {
    @Test
    func walletContextReadinessUsesAOneShotSignal() async {
        let gate = AppRootWalletContextReadinessGate()
        let waiter = Task { await gate.wait() }

        await Task.yield()
        gate.resolve(true)
        gate.resolve(false)

        #expect(await waiter.value)
        #expect(await gate.wait())
    }

    @Test
    func cancelledWalletContextReadinessReleasesEveryWaiter() async {
        let gate = AppRootWalletContextReadinessGate()
        let first = Task { await gate.wait() }
        let second = Task { await gate.wait() }

        await Task.yield()
        gate.resolve(false)

        #expect(!(await first.value))
        #expect(!(await second.value))
    }

    @Test
    func completionWaitsForTheChildSheetDismissalBoundary() {
        var completion = WalletSetupSheetCompletion()

        let queued = completion.queue(
            walletAddress: " 0x1234567890abcdef "
        )
        #expect(queued)
        #expect(
            completion.pendingWalletAddress
                == "0x1234567890abcdef"
        )
        #expect(
            completion.consumeAfterSheetDismissal()
                == "0x1234567890abcdef"
        )
        #expect(completion.consumeAfterSheetDismissal() == nil)
    }

    @Test
    func cancelledSetupCannotCompleteAfterDismissal() {
        var completion = WalletSetupSheetCompletion()

        let queued = completion.queue(walletAddress: "TWalletAddress")
        #expect(queued)
        completion.cancel()

        #expect(completion.consumeAfterSheetDismissal() == nil)
    }

    @Test
    func emptyAddressCannotDismissTheSetupFlow() {
        var completion = WalletSetupSheetCompletion()

        let queued = completion.queue(walletAddress: "   ")
        #expect(!queued)
        #expect(completion.pendingWalletAddress == nil)
    }
}

@MainActor
@Suite(.serialized)
struct WalletSetupActivationTests {
    @Test
    func successAndOpenShareActivationEvenWhenSuccessIsDismissed() async {
        let activation = WalletSetupActivation()
        let gate = WalletSwitcherTestGate<Bool>()
        var calls = 0
        var activated = false
        let success = Task {
            await activation.prepare(address: "new-wallet") { _ in
                calls += 1
                let ready = await gate.wait()
                activated = ready
                return ready
            }
        }
        while !gate.isWaiting { await Task.yield() }
        let open = Task {
            await activation.prepare(address: "new-wallet") { _ in
                Issue.record("Open must join the pending background activation")
                return false
            }
        }
        await Task.yield()
        success.cancel()
        gate.resume(true)
        #expect(await success.value)
        #expect(await open.value)
        #expect(activated)
        #expect(calls == 1)
        #expect(await activation.prepare(address: "new-wallet") { _ in
            Issue.record("An active wallet must not be loaded again")
            return false
        })
    }

    @Test
    func failedActivationCanRetryWithoutRepeatingPersistence() async {
        let activation = WalletSetupActivation()
        #expect(!(await activation.prepare(address: "new-wallet") { _ in false }))
        #expect(await activation.prepare(address: "new-wallet") { _ in true })
        #expect(await activation.prepare(address: "another-wallet") { _ in true })
    }

    @Test(arguments: [false, true])
    func creationActivatesBeforeOpenAndSurvivesClosingTheSuccessScreen(homeAdd: Bool) async throws {
        let database = try WalletDatabase.temporary()
        let draft = try WalletSwitcherSetupTestFixtures.creation()
        let activation = WalletSetupActivation()
        let gate = WalletSwitcherTestGate<Bool>()
        var prepared: String?
        var opened = false
        var activated = false
        var secretReference: String?
        defer {
            gate.resume(true)
            if let secretReference {
                try? WalletSecretVault.shared.deleteIfPresent(reference: secretReference)
            }
        }
        let host = try NativeListTestHost {
            if homeAdd {
                HomeWalletAddSheet(database: database, action: .create) { address in
                    prepared = address
                    let ready = await gate.wait()
                    activated = ready
                    return ready
                }
            } else {
                SettingsWalletCreationFlow(
                    database: database, draft: draft,
                    onPrepareWalletForOpen: { address in
                        prepared = address
                        return await activation.prepare(address: address) { _ in
                            let ready = await gate.wait()
                            activated = ready
                            return ready
                        }
                    },
                    onCompleted: { _ in opened = true }
                )
            }
        }
        defer { host.close() }
        _ = try await host.list()
        let label = WalletAppLanguage.localizedBundle(for: "en")
            .localizedString(forKey: "common.continue", value: nil, table: nil)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            host.accessibilityAction(label: label, in: host.rootView) != nil
        }
        let next = try #require(host.accessibilityAction(label: label, in: host.rootView))
        #expect(next.accessibilityActivate())
        for _ in 0..<500 {
            if gate.isWaiting { break }
            host.rootView.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(gate.isWaiting)
        #expect(prepared != nil)
        #expect(!opened)
        let selected = try #require(try await database.selectedWalletIdentity())
        #expect(selected.address == prepared)
        if !homeAdd { #expect(selected.address == draft.address) }
        secretReference = try await database.pool.read {
            try DBWalletRecord.fetchOne($0, key: selected.walletID)?.secretKeyReference
        }
        host.close()
        gate.resume(true)
        for _ in 0..<100 where !activated { await Task.yield() }
        #expect(activated)
        #expect(!opened)
        #expect(try await database.selectedWalletIdentity()?.walletID == selected.walletID)
    }
}
