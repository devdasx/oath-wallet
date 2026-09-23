import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor @Suite(.serialized)
struct SendStatusCapsuleTests {
    @Test func onlyDeliberateUpwardTravelDismisses() {
        for translation in [CGSize.zero, CGSize(width: 0, height: -12),
                            CGSize(width: 0, height: 80), CGSize(width: 90, height: -40),
                            CGSize(width: -90, height: -40), CGSize(width: 0, height: -.infinity)] {
            #expect(!SendStatusCapsule.shouldDismiss(translation: translation))
        }
        for x: CGFloat in [-20, 0, 20] {
            #expect(SendStatusCapsule.shouldDismiss(translation: CGSize(width: x, height: -60)))
        }
    }

    @Test(arguments: [false, true])
    func hiddenSubmissionReappearsForEitherTerminalResultAndCanBeDismissedAgain(fails: Bool) async throws {
        let database = try WalletDatabase.temporary()
        _ = try await SendRecipientHistoryTestFixtures.seed(database)
        let receipt = SendRecipientHistoryTestFixtures.receipt(hash: "0x" + String(repeating: "c", count: 64))
        let operation = SendOperation(database: database,
            draft: SendEntryTestFixtures.draft(recipient: receipt.toAddress, amount: receipt.amount),
            walletAddress: receipt.fromAddress, nativeUnitUSDPrice: nil, statusReader: { _ in .confirmed })
        let store = SendActivityStore(operations: [operation])
        let (stream, continuation) = AsyncStream<SendTransactionSubmissionOutcome>.makeStream()
        operation.start {
            var iterator = stream.makeAsyncIterator()
            let outcome = try #require(await iterator.next())
            if fails { throw SendTransactionSubmissionError.broadcastRejected(code: "rejected", message: "Rejected") }
            return outcome
        }
        #expect(store.visibleOperation(walletAddress: receipt.fromAddress)?.id == operation.id)
        store.dismissCapsule(operation)
        #expect(operation.isSubmitting)
        #expect(store.visibleOperation(walletAddress: receipt.fromAddress) == nil)
        #expect(store.operations.contains { $0.id == operation.id })
        let hiddenPresentationID = operation.capsulePresentationID
        continuation.yield(.init(receipt: receipt, localTransactionID: nil, localPersistenceWarningCode: nil))
        continuation.finish()
        await operation.waitUntilSettled()
        #expect(!operation.isSubmitting)
        #expect(operation.receiptVisualStatus == (fails ? .failed : .confirmed))
        #expect(store.visibleOperation(walletAddress: receipt.fromAddress)?.id == operation.id)
        #expect(operation.capsulePresentationID != hiddenPresentationID)
        #expect(operation.capsuleStatus == (fails ? .failed : .confirmed))
        store.dismissCapsule(operation)
        #expect(store.visibleOperation(walletAddress: receipt.fromAddress) == nil)
        #expect(store.operations.contains { $0.id == operation.id })
    }

    @Test(arguments: [SendTransactionNetworkStatus.confirmed, .failed])
    func lateTerminalResultReappearsAheadOfPendingSendsOnlyOnce(status: SendTransactionNetworkStatus) async throws {
        let database = try WalletDatabase.temporary()
        _ = try await SendRecipientHistoryTestFixtures.seed(database)
        let receipt = SendRecipientHistoryTestFixtures.receipt(hash: "0x" + String(repeating: "e", count: 64))
        let (statuses, continuation) = AsyncStream<SendTransactionNetworkStatus>.makeStream()
        let monitored = SendOperation(database: database,
            draft: SendEntryTestFixtures.draft(recipient: receipt.toAddress, amount: receipt.amount),
            walletAddress: "first", nativeUnitUSDPrice: nil, statusReader: { _ in
                var iterator = statuses.makeAsyncIterator()
                return try #require(await iterator.next())
            })
        let pending = operation(database: database, wallet: "first")
        let other = operation(database: database, wallet: "second")
        let store = SendActivityStore(operations: [monitored, pending, other])
        monitored.start {
            .init(receipt: receipt, localTransactionID: nil, localPersistenceWarningCode: nil)
        }
        store.dismissCapsule(monitored)
        let hiddenID = monitored.capsulePresentationID
        continuation.yield(status)
        continuation.finish()
        defer { monitored.stopMonitoring() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while monitored.localTransactionID == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(monitored.localTransactionID != nil,
                     "Receipt persistence failed: \(monitored.statusPersistenceWarningCode ?? "none")")
        await monitored.waitUntilSettled()
        #expect(monitored.capsuleStatus == (status == .failed ? .failed : .confirmed))
        #expect(monitored.capsulePresentationID != hiddenID)
        #expect(store.visibleOperation(walletAddress: "first")?.id == monitored.id)
        #expect(store.visibleOperation(walletAddress: "second")?.id == other.id)
        store.dismissCapsule(monitored)
        let terminalID = monitored.capsulePresentationID
        monitored.applyMonitoredStatus(status)
        #expect(monitored.capsulePresentationID == terminalID)
        #expect(monitored.isAcknowledged)
        #expect(store.visibleOperation(walletAddress: "first")?.id == pending.id)
    }

    @Test func unknownOutcomeDoesNotBecomeAFailureAnnouncement() throws {
        let database = try WalletDatabase.temporary()
        let operation = operation(database: database)
        let store = SendActivityStore(operations: [operation])
        store.dismissCapsule(operation)
        let originalID = operation.capsulePresentationID
        operation.phase = .failed(.broadcastOutcomeUnknown(networkID: "eth", code: "timeout"))
        #expect(operation.receiptVisualStatus == .warning)
        #expect(operation.isAcknowledged)
        #expect(operation.capsulePresentationID == originalID)
        #expect(store.visibleOperation(walletAddress: "wallet") == nil)
        operation.applyMonitoredStatus(.confirmed)
        #expect(operation.capsuleStatus == .confirmed)
        #expect(!operation.isAcknowledged)
        #expect(operation.capsulePresentationID != originalID)
        #expect(store.visibleOperation(walletAddress: "wallet")?.id == operation.id)
    }

    @Test func sentAndConfirmingHaveDistinctTitlesWithoutRepeatingDismissedCapsules() throws {
        let database = try WalletDatabase.temporary()
        let operation = operation(database: database)
        let store = SendActivityStore(operations: [operation])
        let receipt = SendRecipientHistoryTestFixtures.receipt(hash: "0x" + String(repeating: "f", count: 64))
        #expect(operation.capsuleStatus == .sending)
        #expect(operation.capsuleStatus.showsProgress)
        operation.phase = .submitted(.init(receipt: receipt, localTransactionID: nil, localPersistenceWarningCode: nil))
        operation.networkStatus = .pending // Initial acceptance, before a status read.
        #expect(operation.capsuleStatus == .sent)
        #expect(operation.capsuleStatus.titleKey == "send.activity.sent")
        #expect(!operation.capsuleStatus.showsProgress)
        store.dismissCapsule(operation)
        let sentID = operation.capsulePresentationID
        operation.applyMonitoredStatus(.pending)
        #expect(operation.capsuleStatus == .confirming)
        #expect(operation.capsuleStatus.titleKey == "send.activity.confirming")
        #expect(operation.capsuleStatus.showsProgress)
        #expect(operation.isAcknowledged)
        #expect(operation.capsulePresentationID == sentID)
        #expect(store.visibleOperation(walletAddress: "wallet") == nil)
        operation.monitoringWarningCode = "http_503"
        #expect(operation.capsuleStatus == .warning)
        #expect(!operation.capsuleStatus.showsProgress)
        operation.applyMonitoredStatus(.pending)
        #expect(operation.capsuleStatus == .confirming)
        operation.applyMonitoredStatus(.confirmed)
        #expect(operation.capsuleStatus.titleKey == "wallet.activity.status.confirmed")
        #expect(!operation.capsuleStatus.showsProgress)
        #expect(store.visibleOperation(walletAddress: "wallet")?.id == operation.id)
    }

    @Test func failureKeepsPriorityOverConfirmedAndSendingTransactions() throws {
        let database = try WalletDatabase.temporary()
        let failed = operation(database: database)
        let confirmed = operation(database: database)
        let sending = operation(database: database)
        failed.phase = .failed(.broadcastRejected(code: "rejected", message: "Rejected"))
        let receipt = SendRecipientHistoryTestFixtures.receipt(hash: "0x" + String(repeating: "a", count: 64))
        confirmed.phase = .submitted(.init(receipt: receipt, localTransactionID: nil, localPersistenceWarningCode: nil))
        confirmed.applyMonitoredStatus(.confirmed)
        let store = SendActivityStore(operations: [failed, confirmed, sending])
        #expect(failed.capsuleStatus.titleKey == "wallet.activity.status.failed")
        #expect(store.visibleOperation(walletAddress: "wallet")?.id == failed.id)
        store.dismissCapsule(failed)
        #expect(store.visibleOperation(walletAddress: "wallet")?.id == confirmed.id)
        store.dismissCapsule(confirmed)
        #expect(store.visibleOperation(walletAddress: "wallet")?.id == sending.id)
    }

    @Test func dismissalIsScopedToOneOperationAndOneWallet() throws {
        let database = try WalletDatabase.temporary()
        let hidden = operation(database: database, wallet: "first")
        let next = operation(database: database, wallet: "first")
        let other = operation(database: database, wallet: "second")
        let store = SendActivityStore(operations: [hidden, next, other])
        #expect(store.visibleOperation(walletAddress: "first")?.id == hidden.id)
        store.dismissCapsule(hidden)
        #expect(store.visibleOperation(walletAddress: "first")?.id == next.id)
        #expect(store.visibleOperation(walletAddress: "second")?.id == other.id)
        store.dismissCapsule(next)
        #expect(store.visibleOperation(walletAddress: "first") == nil)
        #expect(!other.isAcknowledged)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func nativeCapsuleUpdatesStatusAndSupportsOpeningAndDismissal(layout: NativeListTestLayout) async throws {
        let database = try WalletDatabase.temporary()
        let operation = operation(database: database)
        var opens = 0
        var dismissals = 0
        let host = try NativeListTestHost(layout: layout) {
            SendStatusCapsule(operation: operation, onOpen: { opens += 1 }, onDismiss: { dismissals += 1 })
                .frame(maxWidth: 560)
                .padding(16)
        }
        defer { host.close() }
        let language = layout.direction == .rightToLeft ? "ar" : "en"
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        func title(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: nil) }
        func capsule() -> NSObject? { SendEntryUIProbe.element("sendStatusCapsule", in: host.rootView) }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            capsule()?.accessibilityLabel?.contains(title("send.activity.sending")) == true
        }
        #expect(!SendEntryUIProbe.views(UIActivityIndicatorView.self, in: host.rootView).isEmpty)
        #expect(capsule()?.accessibilityActivate() == true)
        #expect(opens == 1)

        let receipt = SendRecipientHistoryTestFixtures.receipt(hash: "0x" + String(repeating: "d", count: 64))
        operation.phase = .submitted(.init(receipt: receipt, localTransactionID: nil, localPersistenceWarningCode: nil))
        try await SendEntryUIProbe.wait(in: host.rootView) {
            capsule()?.accessibilityLabel?.contains(title("send.activity.sent")) == true
        }
        #expect(SendEntryUIProbe.views(UIActivityIndicatorView.self, in: host.rootView).isEmpty)
        operation.applyMonitoredStatus(.pending)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            capsule()?.accessibilityLabel?.contains(title("send.activity.confirming")) == true
        }
        #expect(!SendEntryUIProbe.views(UIActivityIndicatorView.self, in: host.rootView).isEmpty)
        operation.applyMonitoredStatus(.confirmed)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            capsule()?.accessibilityLabel?.contains(title("wallet.activity.status.confirmed")) == true
        }
        #expect(SendEntryUIProbe.views(UIActivityIndicatorView.self, in: host.rootView).isEmpty)
        operation.networkStatus = .failed
        try await SendEntryUIProbe.wait(in: host.rootView) {
            capsule()?.accessibilityLabel?.contains(title("wallet.activity.status.failed")) == true
        }
        operation.networkStatus = nil
        operation.phase = .failed(.broadcastOutcomeUnknown(networkID: "eth", code: "timeout"))
        try await SendEntryUIProbe.wait(in: host.rootView) {
            capsule()?.accessibilityLabel?.contains(title("send.broadcast.warning.title")) == true
        }
        #expect(capsule()?.accessibilityPerformEscape() == true)
        _ = capsule()?.accessibilityPerformEscape()
        _ = capsule()?.accessibilityActivate()
        #expect(dismissals == 1)
        #expect(opens == 1)
    }

    @Test(arguments: NativeListTestLayout.allCases, [false, true])
    func dismissedRootCapsuleReturnsOnTerminalResultAndRemainsInteractive(layout: NativeListTestLayout, confirms: Bool) async throws {
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        let operation = operation(database: database)
        let store = SendActivityStore(operations: [operation])
        store.hasDismissedSendSheet = true
        let host = try NativeListTestHost(layout: layout) {
            Color.clear.modifier(SendActivityPresentation(
                store: store, walletAddress: "wallet", canShow: true, isLocked: false,
                database: database, securitySettings: .secureDefault, modalCallbacks: .noOp,
                onAuthenticated: {}, onRetry: { _ in }
            ))
            .environment(settings)
            .environment(\.walletCurrencyContext, SendEntryTestFixtures.currency)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendStatusCapsule", in: host.rootView) != nil
        }
        let capsule = try #require(SendEntryUIProbe.element("sendStatusCapsule", in: host.rootView))
        #expect(capsule.accessibilityPerformEscape())
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendStatusCapsule", in: host.rootView) == nil
        }
        #expect(operation.isSubmitting)
        #expect(store.operations.count == 1)
        #expect(store.presentedOperation == nil)
        if confirms {
            let receipt = SendRecipientHistoryTestFixtures.receipt(hash: "0x" + String(repeating: "b", count: 64))
            operation.phase = .submitted(.init(receipt: receipt, localTransactionID: nil, localPersistenceWarningCode: nil))
            operation.applyMonitoredStatus(.confirmed)
        } else {
            operation.phase = .failed(.broadcastRejected(code: "rejected", message: "Rejected"))
        }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendStatusCapsule", in: host.rootView) != nil
        }
        let returnedCapsule = try #require(SendEntryUIProbe.element("sendStatusCapsule", in: host.rootView))
        #expect(!returnedCapsule.accessibilityTraits.contains(.notEnabled))
        #expect(returnedCapsule.accessibilityActivate())
        #expect(store.presentedOperation?.id == operation.id)
        store.finishDetails(operation)
        #expect(operation.isAcknowledged)
        #expect(store.visibleOperation(walletAddress: "wallet") == nil)
    }

    @Test(arguments: [SendOperation.CapsuleStatus.sending, .sent, .confirming, .failed, .warning, .confirmed])
    func confirmingAndConfirmedCapsulesDismissAfterThreeSeconds(status: SendOperation.CapsuleStatus) async throws {
        let database = try WalletDatabase.temporary()
        let operation = operation(database: database)
        setStatus(status, on: operation)
        var appeared = false
        var dismissalTimes: [ContinuousClock.Instant] = []
        let mountedAt = ContinuousClock.now
        let host = try NativeListTestHost {
            SendStatusCapsule(operation: operation, onOpen: {}, onDismiss: {
                dismissalTimes.append(.now)
            })
            .onAppear { appeared = true }
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) { appeared }
        // These waits exercise the actual user-requested deadline, not layout readiness.
        try await Task.sleep(for: .seconds(1))
        #expect(dismissalTimes.isEmpty)
        if status == .confirmed || status == .confirming {
            try await SendEntryUIProbe.wait(in: host.rootView) { !dismissalTimes.isEmpty }
            #expect(dismissalTimes.count == 1)
            let dismissedAt = try #require(dismissalTimes.first)
            #expect(mountedAt.duration(to: dismissedAt) >= .seconds(3))
        } else {
            try await Task.sleep(for: .milliseconds(2300))
            #expect(dismissalTimes.isEmpty)
            #expect(!operation.isAcknowledged)
        }
    }

    @Test func changingConfirmedToFailedCancelsAutomaticDismissal() async throws {
        let database = try WalletDatabase.temporary()
        let operation = operation(database: database)
        setStatus(.confirmed, on: operation)
        var appeared = false
        var dismissals = 0
        let host = try NativeListTestHost {
            SendStatusCapsule(operation: operation, onOpen: {}, onDismiss: { dismissals += 1 })
                .onAppear { appeared = true }
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) { appeared }
        try await Task.sleep(for: .milliseconds(200))
        operation.networkStatus = .failed
        try await Task.sleep(for: .milliseconds(3300))
        #expect(operation.capsuleStatus == .failed)
        #expect(dismissals == 0)
    }

    @Test(arguments: [SendTransactionNetworkStatus.confirmed, .failed])
    func visibleTerminalResultKeepsTheSameCapsule(status: SendTransactionNetworkStatus) throws {
        let database = try WalletDatabase.temporary()
        let operation = operation(database: database)
        setStatus(.confirming, on: operation)
        let presentationID = operation.capsulePresentationID
        operation.applyMonitoredStatus(status)
        #expect(operation.capsulePresentationID == presentationID)
        #expect(!operation.isAcknowledged)
        #expect(operation.capsuleStatus == (status == .confirmed ? .confirmed : .failed))
        operation.applyMonitoredStatus(status)
        #expect(operation.capsulePresentationID == presentationID)
    }

    @Test func visibleConfirmationRestartsDeadlineWithoutReplacingCapsule() async throws {
        let database = try WalletDatabase.temporary()
        let operation = operation(database: database)
        setStatus(.confirming, on: operation)
        let presentationID = operation.capsulePresentationID
        var appearances = 0
        var disappearances = 0
        var dismissedAt: ContinuousClock.Instant?
        let host = try NativeListTestHost {
            SendStatusCapsule(operation: operation, onOpen: {}, onDismiss: { dismissedAt = .now })
                .onAppear { appearances += 1 }
                .onDisappear { disappearances += 1 }
                .id(operation.capsulePresentationID)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) { appearances == 1 }
        try await Task.sleep(for: .milliseconds(800))
        let confirmedAt = ContinuousClock.now
        operation.applyMonitoredStatus(.confirmed)
        // Pass the original Confirming deadline while keeping the new one open.
        try await Task.sleep(for: .milliseconds(2400))
        #expect(dismissedAt == nil)
        #expect(appearances == 1)
        #expect(disappearances == 0)
        #expect(operation.capsulePresentationID == presentationID)
        operation.applyMonitoredStatus(.confirmed)
        try await SendEntryUIProbe.wait(in: host.rootView) { dismissedAt != nil }
        let completion = try #require(dismissedAt)
        #expect(confirmedAt.duration(to: completion) >= .seconds(3))
        #expect(confirmedAt.duration(to: completion) < .seconds(5))
    }

    @Test func automaticallyHiddenConfirmingReturnsOnceForConfirmation() async throws {
        let database = try WalletDatabase.temporary()
        let operation = operation(database: database)
        setStatus(.confirming, on: operation)
        let store = SendActivityStore(operations: [operation])
        let toolbar = WalletPendingActivityStore()
        let confirmingID = operation.capsulePresentationID
        let host = try NativeListTestHost {
            SendActivityGroupCapsule(store: store, walletAddress: "wallet", maximumHeight: 560)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendStatusCapsule", in: host.rootView) != nil
        }
        try await Task.sleep(for: .seconds(1))
        #expect(!operation.isAcknowledged)
        try await SendEntryUIProbe.wait(in: host.rootView) { operation.isAcknowledged }
        #expect(store.visibleOperation(walletAddress: "wallet") == nil)
        // The toolbar retains a pending operation after automatic banner dismissal.
        #expect(toolbar.items(operations: store.operations, walletAddress: "wallet").count == 1)
        operation.applyMonitoredStatus(.confirmed)
        #expect(!operation.isAcknowledged)
        #expect(operation.capsulePresentationID != confirmingID)
        #expect(store.visibleOperation(walletAddress: "wallet")?.id == operation.id)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendStatusCapsule", in: host.rootView) != nil
        }
        try await Task.sleep(for: .seconds(1))
        #expect(!operation.isAcknowledged)
        try await SendEntryUIProbe.wait(in: host.rootView) { operation.isAcknowledged }
        #expect(store.operations.count == 1)
        let confirmedID = operation.capsulePresentationID
        operation.applyMonitoredStatus(.confirmed)
        #expect(operation.isAcknowledged)
        #expect(operation.capsulePresentationID == confirmedID)
    }

    @Test(arguments: [SendOperation.CapsuleStatus.confirming, .confirmed])
    func seenCapsuleExpiresWhileAwayAndDoesNotReappear(status: SendOperation.CapsuleStatus) async throws {
        let database = try WalletDatabase.temporary()
        let operation = operation(database: database)
        setStatus(status, on: operation)
        let visibility = CapsuleVisibility()
        var appearances = 0
        var disappearances = 0
        var dismissals = 0
        let host = try NativeListTestHost {
            CapsuleVisibilityHost(operation: operation, visibility: visibility,
                                  onDismiss: { dismissals += 1 },
                                  onAppear: { appearances += 1 },
                                  onDisappear: { disappearances += 1 })
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) { appearances == 1 }
        try await Task.sleep(for: .milliseconds(200))
        visibility.isVisible = false
        try await SendEntryUIProbe.wait(in: host.rootView) { disappearances == 1 }
        try await Task.sleep(for: .milliseconds(3300))
        #expect(dismissals == 1)
        #expect(operation.isAcknowledged)
        // A duplicate network observation and navigation back must not replay the same result.
        operation.applyMonitoredStatus(status == .confirmed ? .confirmed : .pending)
        visibility.isVisible = true
        try await Task.sleep(for: .seconds(1))
        #expect(appearances == 1)
        #expect(dismissals == 1)
        #expect(operation.isAcknowledged)
    }

    @Test func returningBeforeExpiryKeepsTheOriginalDeadline() async throws {
        let database = try WalletDatabase.temporary()
        let operation = operation(database: database)
        setStatus(.confirmed, on: operation)
        let visibility = CapsuleVisibility()
        var appearances = 0
        var disappearances = 0
        var dismissedAt: ContinuousClock.Instant?
        let host = try NativeListTestHost {
            CapsuleVisibilityHost(operation: operation, visibility: visibility,
                                  onDismiss: { dismissedAt = .now },
                                  onAppear: { appearances += 1 },
                                  onDisappear: { disappearances += 1 })
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) { appearances == 1 }
        try await Task.sleep(for: .milliseconds(800))
        visibility.isVisible = false
        try await SendEntryUIProbe.wait(in: host.rootView) { disappearances == 1 }
        try await Task.sleep(for: .milliseconds(800))
        let returnedAt = ContinuousClock.now
        visibility.isVisible = true
        try await SendEntryUIProbe.wait(in: host.rootView) { appearances == 2 }
        try await SendEntryUIProbe.wait(in: host.rootView) { operation.isAcknowledged }
        let completedAt = try #require(dismissedAt)
        #expect(returnedAt.duration(to: completedAt) < .seconds(2.5),
                "Returning must use the remaining interval, not start another three seconds")
    }

    @Test func confirmationReceivedWhileAwayWaitsUntilSeen() async throws {
        let database = try WalletDatabase.temporary()
        let operation = operation(database: database)
        setStatus(.confirming, on: operation)
        let visibility = CapsuleVisibility()
        var appearances = 0
        var disappearances = 0
        var dismissedAt: ContinuousClock.Instant?
        let host = try NativeListTestHost {
            CapsuleVisibilityHost(operation: operation, visibility: visibility,
                                  onDismiss: { dismissedAt = .now },
                                  onAppear: { appearances += 1 },
                                  onDisappear: { disappearances += 1 })
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) { appearances == 1 }
        try await Task.sleep(for: .milliseconds(200))
        visibility.isVisible = false
        try await SendEntryUIProbe.wait(in: host.rootView) { disappearances == 1 }
        operation.applyMonitoredStatus(.confirmed)
        try await Task.sleep(for: .milliseconds(3300))
        #expect(dismissedAt == nil)
        #expect(!operation.isAcknowledged)
        let shownAgainAt = ContinuousClock.now
        visibility.isVisible = true
        try await SendEntryUIProbe.wait(in: host.rootView) { appearances == 2 }
        try await Task.sleep(for: .seconds(1))
        #expect(dismissedAt == nil)
        try await SendEntryUIProbe.wait(in: host.rootView) { operation.isAcknowledged }
        let completedAt = try #require(dismissedAt)
        #expect(shownAgainAt.duration(to: completedAt) >= .seconds(3))
    }

    @Test(arguments: [false, true])
    func ownerDismissalOrClearCancelsAnUnfinishedDeadline(clearStore: Bool) async throws {
        let database = try WalletDatabase.temporary()
        let operation = operation(database: database)
        setStatus(.confirming, on: operation)
        let store = SendActivityStore(operations: [operation])
        var automaticDismissals = 0
        operation.capsuleDismissal.start(for: operation, identity: .init(operation: operation)) {
            automaticDismissals += 1
        }
        if clearStore { store.clear() } else { store.dismissCapsule(operation) }
        try await Task.sleep(for: .milliseconds(3300))
        #expect(automaticDismissals == 0)
        #expect(operation.isAcknowledged == !clearStore)
    }

    @Test func dismissalTimerDoesNotRetainAnUnownedOperation() throws {
        let database = try WalletDatabase.temporary()
        weak var released: SendOperation?
        do {
            let operation = operation(database: database)
            released = operation
            setStatus(.confirmed, on: operation)
            operation.capsuleDismissal.start(for: operation, identity: .init(operation: operation)) {}
        }
        #expect(released == nil)
    }

    @Test func queuedConfirmedResultGetsItsFullVisibleIntervalThenRevealsPendingSend() async throws {
        let database = try WalletDatabase.temporary()
        let failed = operation(database: database)
        let confirmed = operation(database: database)
        let pending = operation(database: database)
        setStatus(.failed, on: failed)
        setStatus(.confirmed, on: confirmed)
        setStatus(.confirming, on: pending)
        let store = SendActivityStore(operations: [failed, confirmed, pending])
        store.hasDismissedSendSheet = true
        let settings = WalletSettingsStore(database: database)
        var appeared = false
        let host = try NativeListTestHost {
            Color.clear.modifier(SendActivityPresentation(
                store: store, walletAddress: "wallet", canShow: true, isLocked: false,
                database: database, securitySettings: .secureDefault, modalCallbacks: .noOp,
                onAuthenticated: {}, onRetry: { _ in }
            ))
            .environment(settings)
            .environment(\.walletCurrencyContext, SendEntryTestFixtures.currency)
            .onAppear { appeared = true }
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) { appeared }
        try await Task.sleep(for: .milliseconds(3300))
        #expect(store.visibleOperation(walletAddress: "wallet")?.id == failed.id)
        #expect(!confirmed.isAcknowledged)
        store.dismissCapsule(failed)
        try await Task.sleep(for: .seconds(1))
        #expect(store.visibleOperation(walletAddress: "wallet")?.id == confirmed.id)
        #expect(!confirmed.isAcknowledged)
        try await SendEntryUIProbe.wait(in: host.rootView) { confirmed.isAcknowledged }
        #expect(store.visibleOperation(walletAddress: "wallet")?.id == pending.id)
        #expect(store.operations.count == 3)
        #expect(!pending.isAcknowledged)
    }

    @MainActor @Observable fileprivate final class CapsuleVisibility {
        var isVisible = true
    }

    private struct CapsuleVisibilityHost: View {
        let operation: SendOperation
        let visibility: CapsuleVisibility
        let onDismiss: @MainActor () -> Void
        let onAppear: () -> Void
        let onDisappear: () -> Void

        var body: some View {
            if visibility.isVisible && !operation.isAcknowledged {
                SendStatusCapsule(operation: operation, onOpen: {}, onDismiss: onDismiss)
                    .onAppear(perform: onAppear)
                    .onDisappear(perform: onDisappear)
            }
        }
    }

    private func setStatus(_ status: SendOperation.CapsuleStatus, on operation: SendOperation) {
        if status == .sending { return }
        let receipt = SendRecipientHistoryTestFixtures.receipt(hash: "0x" + String(repeating: "9", count: 64))
        operation.phase = .submitted(.init(receipt: receipt, localTransactionID: nil, localPersistenceWarningCode: nil))
        switch status {
        case .sending, .sent: break
        case .confirming: operation.applyMonitoredStatus(.pending)
        case .confirmed: operation.applyMonitoredStatus(.confirmed)
        case .failed: operation.applyMonitoredStatus(.failed)
        case .warning: operation.monitoringWarningCode = "http_503"
        }
    }

    private func operation(database: WalletDatabase, wallet: String = "wallet") -> SendOperation {
        SendOperation(database: database, draft: SendEntryTestFixtures.draft(),
                      walletAddress: wallet, nativeUnitUSDPrice: nil)
    }
}
