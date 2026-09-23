import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct UniHapticActionFeedbackTests {
    @MainActor
    private final class Output {
        var events: [UniHaptic] = []
        var active = true
        lazy var engine = UniHapticEngine(
            isEnabled: true,
            isApplicationActive: { [unowned self] in active },
            output: { [unowned self] in events.append($0) }
        )
    }

    @Test func nativeActionRunsOnceBeforeDefaultFeedback() {
        let output = Output()
        var invocations = 0
        output.engine.performAction(.tap) {
            invocations += 1
            #expect(output.events.isEmpty)
        }
        #expect(invocations == 1)
        #expect(output.events == [.tap])
    }

    @Test(arguments: [UniHaptic.selection, .successQuiet, .success, .error, .passcodeDigit, .walletCreated])
    func existingSemanticFeedbackReplacesFallback(_ event: UniHaptic) {
        let output = Output()
        output.engine.performAction(.tap) { output.engine.play(event) }
        #expect(output.events == [event])
    }

    @Test func nestedSharedButtonDoesNotDoubleFire() {
        let output = Output()
        output.engine.performAction(.tap) {
            output.engine.performAction(.commit) {}
        }
        #expect(output.events == [.commit])
    }

    @Test func nestedCopyOrValidationTakesPriorityOverCommit() {
        let output = Output()
        output.engine.performAction(.tap) {
            output.engine.performAction(.commit) { output.engine.play(.successQuiet) }
        }
        #expect(output.events == [.successQuiet])
    }

    @Test func silentPolicySuppressesParentDefault() {
        let output = Output()
        output.engine.performAction(.tap) { output.engine.performAction(nil) {} }
        #expect(output.events.isEmpty)
    }

    @Test func silentDefaultStillAllowsActualFailureFeedback() {
        let output = Output()
        output.engine.performAction(nil) { output.engine.play(.error) }
        #expect(output.events == [.error])
    }

    @Test func separateRapidTapsAreNotDebounced() {
        let output = Output()
        for _ in 0..<20 { output.engine.performAction(.tap) {} }
        #expect(output.events == Array(repeating: .tap, count: 20))
    }

    @Test func outcomeAfterActivationHasItsOwnFeedback() async {
        let output = Output()
        output.engine.performAction(.commit) {}
        await Task.yield()
        output.engine.play(.success)
        #expect(output.events == [.commit, .success])
    }

    @Test func disabledPreferenceSuppressesAllAppFeedbackWithoutBlockingAction() {
        let output = Output()
        output.engine.configure(isEnabled: false)
        var invoked = false
        output.engine.performAction(.tap) {
            invoked = true
            output.engine.play(.success)
        }
        #expect(invoked)
        #expect(output.events.isEmpty)
    }

    @Test func backgroundOutcomeStaysSilent() {
        let output = Output()
        output.active = false
        output.engine.performAction(.tap) { output.engine.play(.success) }
        #expect(output.events.isEmpty)
    }

    @Test func preferenceOffPreviewDoesNotLeakDefaultTap() {
        let output = Output()
        output.engine.performAction(.tap) { output.engine.setEnabled(false) }
        output.engine.performAction(.tap) {}
        #expect(output.events == [.whisper])
        #expect(!output.engine.isEnabled)
    }

    @Test func preferenceOnProducesOnePreview() {
        let output = Output()
        output.engine.configure(isEnabled: false)
        output.engine.performAction(.tap) { output.engine.setEnabled(true) }
        #expect(output.events == [.successQuiet])
        #expect(output.engine.isEnabled)
    }

    @Test func selectionBindingRespondsToChangesButNotRestorationOrNoOp() {
        let output = Output()
        var path: [Int] = []
        let binding = Binding(get: { path }, set: { path = $0 })
            .hapticSelection(engine: output.engine)
        path = [1] // Direct state restoration must stay silent.
        binding.wrappedValue = [1] // Repeated native write must stay silent.
        #expect(output.events.isEmpty)
        binding.wrappedValue = [1, 2]
        binding.wrappedValue = [1]
        #expect(path == [1])
        #expect(output.events == [.selection, .selection])
    }

    @Test func selectionBindingPreservesInteractiveTransaction() {
        let output = Output()
        var path: [Int] = [1]
        var receivedDisablesAnimations = false
        let binding = Binding(get: { path }, set: { value, transaction in
            path = value
            receivedDisablesAnimations = transaction.disablesAnimations
        }).hapticSelection(engine: output.engine)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        binding.transaction(transaction).wrappedValue = []
        #expect(path.isEmpty)
        #expect(receivedDisablesAnimations)
        #expect(output.events == [.selection])
    }

    @Test func existingSelectionCallbackDoesNotDoubleFire() {
        let output = Output()
        var path: [Int] = [1]
        let binding = Binding(get: { path }, set: {
            path = $0
            output.engine.play(.selection)
        }).hapticSelection(engine: output.engine)
        binding.wrappedValue = []
        #expect(output.events == [.selection])
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func nativeToolbarButtonActivationAndDisabledState(layout: NativeListTestLayout) async throws {
        let output = Output()
        var invocations = 0
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                Text("settings.title")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("common.continue", action: UniHaptic.action(.tap, engine: output.engine) {
                                invocations += 1
                            })
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("common.continue", action: UniHaptic.action(.tap, engine: output.engine) {
                                invocations += 100
                            })
                            .disabled(true)
                        }
                    }
            }
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            host.navigationController?.topViewController?.navigationItem.leadingItemGroups.first?.barButtonItems.first != nil
        }
        #expect(output.events.isEmpty) // Rendering a control must never vibrate.
        let item = try #require(host.navigationController?.topViewController?.navigationItem)
        let enabled = try #require(item.leadingItemGroups.first?.barButtonItems.first)
        let disabled = try #require(item.trailingItemGroups.first?.barButtonItems.first)
        #expect(enabled.isEnabled)
        #expect(!disabled.isEnabled)
        let action = try #require(enabled.action)
        #expect(UIApplication.shared.sendAction(action, to: enabled.target, from: enabled, for: nil))
        #expect(invocations == 1)
        #expect(output.events == [.tap])
        output.engine.configure(isEnabled: false)
        #expect(UIApplication.shared.sendAction(action, to: enabled.target, from: enabled, for: nil))
        #expect(invocations == 2)
        #expect(output.events == [.tap])
    }
}
