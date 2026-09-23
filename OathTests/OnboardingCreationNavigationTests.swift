import Foundation
import Observation
import SwiftUI
import UIKit
import Testing
@testable import Aperture

struct OnboardingCreationNavigationTests {
    @Test
    func everyPrivateKeyNetworkHasLocalizedGuidanceInEveryShippedLanguage() throws {
        let languages = Bundle.main.localizations.filter { $0 != "Base" }
        #expect(languages.contains("en"))
        #expect(languages.count > 1)

        for language in languages {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for network in PrivateKeyImportNetwork.allCases {
                for key in [network.requirementKey, network.titleKey] {
                    let value = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
                    #expect(value != "MISSING", "Missing \(key) in \(language)")
                    #expect(value != key, "Raw key \(key) in \(language)")
                    #expect(!value.isEmpty)
                    #expect(!value.contains("%d") && !value.contains("%1$d"))
                }
            }
        }
    }

    @Test
    func quickWalletGenerationStillCreatesTwelveWords() throws {
        let draft = try WalletCoreService.generateEVMWallet()

        #expect(draft.words.count == 12)
        #expect(draft.mnemonic.split(separator: " ").count == 12)
        #expect(!draft.address.isEmpty)
    }

    @Test
    func physicalEntropyPushKeepsImportOptionsAsItsBackDestination() {
        let importPath: [OnboardingDestination] = [.importOptions]
        let nextPath = OnboardingNavigationTransition.pushing(
            .physicalEntropy(OnboardingPhysicalEntropyNavigation.initialDestination),
            onto: importPath
        )

        #expect(nextPath == [.importOptions, .physicalEntropy(.input)])
        #expect(Array(nextPath.dropLast()) == importPath)
    }

    @Test
    func physicalEntropyCreationUsesIndependentOrderedScreens() {
        #expect(
            OnboardingPhysicalEntropyNavigation.initialDestination
                == .input
        )
        #expect(
            OnboardingPhysicalEntropyNavigation.destination(
                after: .entropy
            ) == .recoveryPhrase
        )
        #expect(
            OnboardingPhysicalEntropyNavigation.destination(
                after: .recoveryPhrase
            ) == .passcode
        )
        #expect(
            OnboardingPhysicalEntropyNavigation.destination(
                after: .passcode
            ) == .success
        )
    }

    @Test
    func physicalEntropyPasscodeConfirmsInOneScreenOwnedState() {
        var state = OnboardingPhysicalEntropyPasscodeState()

        #expect(state.step == .enter)
        #expect(
            state.submit("123456") == .awaitingConfirmation
        )
        #expect(state.step == .confirm)
        #expect(
            state.submit("123456") == .confirmed("123456")
        )
    }

    @Test
    func physicalEntropyPasscodeMismatchRestartsBothEntries() {
        var state = OnboardingPhysicalEntropyPasscodeState()

        #expect(
            state.submit("123456") == .awaitingConfirmation
        )
        #expect(state.submit("654321") == .mismatch)
        #expect(state.step == .enter)
        #expect(
            state.submit("654321") == .awaitingConfirmation
        )
        #expect(
            state.submit("654321") == .confirmed("654321")
        )
    }

    @Test
    func physicalEntropyCreationUsesTheOnboardingNavigationStack() {
        #expect(
            OnboardingDestination.physicalEntropy(.input)
                .isPhysicalEntropyDestination
        )
        #expect(
            !OnboardingDestination.importOptions
                .isPhysicalEntropyDestination
        )
    }

    @Test
    func physicalEntropyRecoveryOptionsUseOwnedNavigationDestinations() {
        #expect(
            OnboardingDestination.physicalEntropy(.passphrase)
                .isPhysicalEntropyDestination
        )
        #expect(
            OnboardingDestination.physicalEntropy(.wordList)
                .isPhysicalEntropyDestination
        )
        #expect(
            OnboardingPhysicalEntropyDestination.passphrase
                != .wordList
        )
    }

    @Test
    func physicalEntropyPassphraseKeepsWordsAndChangesIdentity() throws {
        let originalDraft = try WalletCoreService.generateEVMWallet(
            entropy: Data(repeating: 0, count: 32)
        )
        let updatedDraft = try OnboardingPhysicalEntropyPassphraseDerivation
            .updatedDraft(
                from: originalDraft,
                passphrase: "Aperture physical entropy"
            )

        #expect(updatedDraft.mnemonic == originalDraft.mnemonic)
        #expect(updatedDraft.words == originalDraft.words)
        #expect(updatedDraft.words.count == 24)
        #expect(updatedDraft.passphrase == "Aperture physical entropy")
        #expect(updatedDraft.address != originalDraft.address)
        #expect(
            updatedDraft.normalizedAddress
                != originalDraft.normalizedAddress
        )
    }

    @Test
    func recoveryPhraseCopyStateChangesToTheCopiedLabel() {
        var state = WalletRecoveryPhraseCopyState.ready

        #expect(
            state.localizationKey
                == "common.copy"
        )

        state.markCopied()
        #expect(state == .copied)
        #expect(
            state.localizationKey
                == "common.copied_to_clipboard"
        )

        state.reset()
        #expect(state == .ready)
    }

    @Test @MainActor
    func clipboardCopyFeedbackResetsAfterExactlyTwoSeconds() async {
        let sleeper = ClipboardFeedbackSleeperProbe()
        let feedback = WalletClipboardCopyFeedback { duration in
            await sleeper.record(duration)
        }

        #expect(
            WalletClipboardCopyFeedback.displayDuration
                == .seconds(2)
        )
        feedback.markCopied()
        #expect(feedback.state == .copied)

        for _ in 0..<100 where feedback.state != .ready {
            await Task.yield()
        }

        #expect(feedback.state == .ready)
        #expect(await sleeper.durations == [.seconds(2)])
    }

    @Test @MainActor
    func clipboardCopyFeedbackCanBeResetImmediately() {
        let feedback = WalletClipboardCopyFeedback(
            duration: .seconds(30)
        )

        feedback.markCopied()
        #expect(feedback.state == .copied)
        feedback.reset()
        #expect(feedback.state == .ready)
    }

    @Test @MainActor
    func clipboardCopyFeedbackUsesSharedLabelsForEveryPayload() {
        let feedback = WalletClipboardCopyFeedback(
            duration: .seconds(30)
        )

        #expect(WalletLocalization.string("common.copy") == "Copy")
        #expect(
            WalletLocalization.string("common.copied_to_clipboard")
                == "Copied to Clipboard"
        )
        #expect(
            feedback.localizationKey
                == "common.copy"
        )

        feedback.markCopied()
        #expect(
            feedback.localizationKey
                == "common.copied_to_clipboard"
        )

        feedback.reset()
        #expect(
            feedback.localizationKey
                == "common.copy"
        )
    }

    @Test
    func onboardingCarouselHasFourOrderedFeaturePages() {
        #expect(
            OnboardingCarouselPage.allCases == [
                .wallet,
                .entropy,
                .openSource,
                .passphrase
            ]
        )
        #expect(OnboardingCarouselPage.wallet.rawValue == 0)
    }

    @Test
    func onboardingCarouselPagesOwnDistinctLocalizedCopy() {
        let pages = OnboardingCarouselPage.allCases

        #expect(Set(pages.map(\.localizedEyebrow)).count == pages.count)
        #expect(Set(pages.map(\.localizedTitle)).count == pages.count)
        #expect(Set(pages.map(\.localizedMessage)).count == pages.count)
    }

    @Test
    func entropyEducationUsesItsOwnSheetRoute() {
        #expect(
            OnboardingCarouselSheet.entropyLearnMore.id
                == "entropyLearnMore"
        )
    }

    @Test
    func passphraseEducationUsesItsOwnSheetRoute() {
        #expect(
            OnboardingCarouselSheet.passphraseLearnMore.id
                == "passphraseLearnMore"
        )
    }

    @Test
    func entropyEducationFactsMatchTheBIP39TwentyFourWordPath() {
        #expect(OnboardingEntropyEducationFacts.entropyBitCount == 256)
        #expect(OnboardingEntropyEducationFacts.entropyByteCount == 32)
        #expect(OnboardingEntropyEducationFacts.checksumBitCount == 8)
        #expect(OnboardingEntropyEducationFacts.encodedBitCount == 264)
        #expect(OnboardingEntropyEducationFacts.bitsPerWord == 11)
        #expect(OnboardingEntropyEducationFacts.recoveryWordCount == 24)
        #expect(
            OnboardingEntropyEducationFacts.wordListEntryCount == 2_048
        )
    }

    @Test
    func creationSuccessPushesDirectlyFromPasscode() {
        let currentPath: [OnboardingDestination] = [.creationPasscode]
        let nextPath = OnboardingNavigationTransition.pushing(
            .walletReady,
            onto: currentPath
        )

        #expect(nextPath == [.creationPasscode, .walletReady])
    }

    @Test
    func creationFailureReplacesThePreparingSuccessScreen() {
        let failure = WalletPersistenceFailure(
            error: WalletCreationPersistenceError.invalidDraft
        )
        let currentPath: [OnboardingDestination] = [
            .creationPasscode,
            .walletReady
        ]

        var nextPath = currentPath
        nextPath[nextPath.count - 1] = .creationFailure(failure)

        #expect(nextPath == [.creationPasscode, .creationFailure(failure)])
    }

    @Test
    func importedWalletNavigatesDirectlyToPreparingSuccess() {
        let currentPath: [OnboardingDestination] = [
            .importOptions,
            .importCredential(.recoveryPhrase),
            .importPasscode
        ]

        let successPath = OnboardingNavigationTransition.pushing(
            .walletReady,
            onto: currentPath
        )
        #expect(
            successPath == [
                .importOptions,
                .importCredential(.recoveryPhrase),
                .importPasscode,
                .walletReady
            ]
        )
    }

    @Test
    func restoredWalletLeavesThePasskeyScreenBeforePersistenceStarts() {
        #expect(
            OnboardingImportPersistenceEntry.destination(
                usesExistingProfileSecurity: true
            ) == .walletReady
        )
        #expect(
            OnboardingImportPersistenceEntry.destination(
                usesExistingProfileSecurity: false
            ) == .importPasscode
        )
    }

    @Test
    func everyOnboardingPasscodeUsesItsOwnNavigationDestination() {
        let destinations: Set<OnboardingDestination> = [
            .creationPasscode,
            .importPasscode,
            .physicalEntropy(.passcode)
        ]

        #expect(destinations.count == 3)
        #expect(
            OnboardingPasscodeCompletion.persistCreatedWallet.destination
                == .creationPasscode
        )
        #expect(
            OnboardingPasscodeCompletion.persistImportedWallet.destination
                == .importPasscode
        )
    }

    @Test
    func quickCreationPushesPasscodeFromWelcome() {
        #expect(
            OnboardingNavigationTransition.pushing(
                .creationPasscode,
                onto: []
            ) == [.creationPasscode]
        )
    }

    @Test
    func importedWalletPasscodePreservesThePreviousCredentialScreen() {
        let entryPoints: [OnboardingDestination] = [
            .importCredential(.recoveryPhrase),
            .restoreICloud
        ] + PrivateKeyImportNetwork.allCases.map {
            .privateKeyCredential($0)
        }

        for entryPoint in entryPoints {
            let currentPath: [OnboardingDestination] = [
                .importOptions,
                entryPoint
            ]
            let nextPath = OnboardingNavigationTransition.pushing(
                .importPasscode,
                onto: currentPath
            )

            #expect(nextPath == currentPath + [.importPasscode])
            #expect(Array(nextPath.dropLast()) == currentPath)
        }
    }

    @Test
    func physicalEntropyPasscodePushKeepsTheRecoveryScreenInTheStack() {
        let currentPath: [OnboardingDestination] = [
            .physicalEntropy(.input),
            .physicalEntropy(.recoveryPhrase)
        ]
        let nextPath = OnboardingNavigationTransition.pushing(
            .physicalEntropy(.passcode),
            onto: currentPath
        )

        #expect(
            nextPath == currentPath + [.physicalEntropy(.passcode)]
        )
        #expect(Array(nextPath.dropLast()) == currentPath)
        #expect(
            OnboardingNavigationTransition.pushing(
                .physicalEntropy(.success),
                onto: nextPath
            ) == nextPath + [.physicalEntropy(.success)]
        )
    }

    @Test
    func importedWalletFailureReplacesThePreparingSuccessDestination() {
        let failure = WalletPersistenceFailure(
            error: WalletCreationPersistenceError.invalidDraft
        )
        let currentPath: [OnboardingDestination] = [
            .importOptions,
            .importCredential(.recoveryPhrase),
            .walletReady
        ]

        var nextPath = currentPath
        nextPath[nextPath.count - 1] = .importFailure(failure)

        #expect(
            nextPath == [
                .importOptions,
                .importCredential(.recoveryPhrase),
                .importFailure(failure)
            ]
        )
    }
}

private actor ClipboardFeedbackSleeperProbe {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }
}

struct AppRootOnboardingCompletionStateTests {
    @Test
    func fundingWaitsForTheMatchingWalletHomeFrame() {
        var state = AppRootOnboardingCompletionState()
        let requestID = UUID()

        state.stage(requestID: requestID, action: .fundWallet)

        #expect(state.isBlockingHomePresentation)
        #expect(
            state.consumePendingAction(for: UUID()) == nil
        )
        #expect(
            state.consumePendingAction(for: requestID) == .fundWallet
        )

        state.beginFundingPresentation()
        #expect(state.isBlockingHomePresentation)
        let didFinishFunding = state.finishFundingPresentation()
        #expect(didFinishFunding)
        #expect(!state.isBlockingHomePresentation)
    }

    @Test
    func backupRetainsRecoveryMaterialUntilItsSheetDismisses() {
        var state = AppRootOnboardingCompletionState()
        let requestID = UUID()
        let action = OnboardingWalletPostOpenAction.backUpWallet(
            walletID: "wallet-1",
            words: ["alpha", "bravo"],
            passphrase: ""
        )

        state.stage(requestID: requestID, action: action)
        #expect(
            state.consumePendingAction(for: requestID) == action
        )
        state.beginBackupPresentation(
            walletID: "wallet-1",
            words: ["alpha", "bravo"],
            passphrase: ""
        )

        #expect(state.backupPresentation?.walletID == "wallet-1")
        #expect(
            state.backupPresentation?.words == ["alpha", "bravo"]
        )
        #expect(state.isBlockingHomePresentation)

        state.backupPresentation = nil
        let didFinishBackup = state.finishBackupPresentation()
        #expect(didFinishBackup)
        #expect(!state.isBlockingHomePresentation)
    }
}

@MainActor
@Suite(.serialized)
struct EntropyMethodSelectorAccessibilityTests {
    @Test
    func presentationFollowsDynamicTypeCategory() {
        for size in DynamicTypeSize.allCases {
            #expect(
                SettingsWalletEntropyMethodSelector.usesMenu(for: size)
                    == size.isAccessibilitySize
            )
        }
    }

    @Test(arguments: [
        NativeListTestLayout.largeTextLTR,
        .largeTextRTL
    ])
    func accessibilitySizesRenderReadableMenu(
        layout: NativeListTestLayout
    ) async throws {
        let host = try NativeListTestHost(layout: layout) {
            EntropyMethodSelectorTestHarness()
        }
        defer { host.close() }

        try await assertReadableMenu(in: host, layout: layout)
    }

    @Test
    func accessibilitySizeUsesMenuOnLandscapeIPad() async throws {
        let host = try NativeListTestHost(layout: .padLandscape) {
            EntropyMethodSelectorTestHarness()
                .environment(\.dynamicTypeSize, .accessibility3)
        }
        defer { host.close() }

        try await assertReadableMenu(in: host, layout: .padLandscape)
    }

    @Test(arguments: [
        NativeListTestLayout.phone,
        .phoneLandscape,
        .pad,
        .padLandscape
    ])
    func regularSizesKeepCompactSegmentedControl(
        layout: NativeListTestLayout
    ) async throws {
        let host = try NativeListTestHost(layout: layout) {
            EntropyMethodSelectorTestHarness()
        }
        defer { host.close() }

        try await SendEntryUIProbe.wait(in: host.rootView) {
            !SendEntryUIProbe.views(
                UISegmentedControl.self,
                in: host.rootView
            ).isEmpty
        }
        let segmentedControl = try #require(
            SendEntryUIProbe.views(
                UISegmentedControl.self,
                in: host.rootView
            ).first
        )
        #expect(segmentedControl.numberOfSegments == 3)
        #expect(
            SendEntryUIProbe.element(
                "entropyMethodSelector.menu",
                in: host.rootView
            ) == nil
        )
    }

    private func assertReadableMenu(
        in host: NativeListTestHost,
        layout: NativeListTestLayout
    ) async throws {
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element(
                "entropyMethodSelector.menu",
                in: host.rootView
            ) != nil
        }
        let menu = try #require(
            SendEntryUIProbe.element(
                "entropyMethodSelector.menu",
                in: host.rootView
            )
        )
        let bundle = WalletAppLanguage.localizedBundle(
            for: layout.direction == .rightToLeft ? "ar" : "en"
        )
        let label = bundle.localizedString(
            forKey: "wallet.creation.entropy.method",
            value: nil,
            table: nil
        )
        let selectedValue = bundle.localizedString(
            forKey: "wallet.creation.entropy.method.dice",
            value: nil,
            table: nil
        )

        #expect(menu.accessibilityLabel == label)
        #expect(menu.accessibilityValue == selectedValue)
        #expect(menu.accessibilityTraits.contains(.button))
        #expect(!menu.accessibilityTraits.contains(.notEnabled))
        #expect(menu.accessibilityFrame.width > 0)
        #expect(menu.accessibilityFrame.height >= 44)
        #expect(
            SendEntryUIProbe.views(
                UISegmentedControl.self,
                in: host.rootView
            ).isEmpty
        )
    }
}

@MainActor
@Suite(.serialized)
struct EntropyInfoPopoverPresentationTests {
    @Test
    func flaggedHistoryEntryExposesItsWarningToVoiceOver() async throws {
        let flaggedIDs = [UUID(), UUID(), UUID()]
        let ordinaryID = UUID()
        let assessment = SettingsWalletEntropyHealthAssessment(
            status: .warning(.dominance(method: .dice)),
            flaggedEntryIDs: Set(flaggedIDs)
        )
        let host = try NativeListTestHost {
            SettingsWalletEntropyRecentInputs(
                entries: [
                    SettingsWalletEntropyEntry(
                        id: flaggedIDs[0],
                        source: .dice(face: 1),
                        contributedBits: 2
                    ),
                    SettingsWalletEntropyEntry(
                        id: flaggedIDs[1],
                        source: .coin(side: .heads),
                        contributedBits: 1
                    ),
                    SettingsWalletEntropyEntry(
                        id: flaggedIDs[2],
                        source: .digit(7),
                        contributedBits: 3
                    ),
                    SettingsWalletEntropyEntry(
                        id: ordinaryID,
                        source: .dice(face: 2),
                        contributedBits: 2
                    )
                ],
                assessment: assessment
            )
            .frame(width: 300)
        }
        defer { host.close() }

        let flaggedIdentifiers = flaggedIDs.map {
            "entropyRecentInput.\($0.uuidString)"
        }
        let ordinaryIdentifier = "entropyRecentInput.\(ordinaryID.uuidString)"
        try await SendEntryUIProbe.wait(in: host.rootView) {
            flaggedIdentifiers.allSatisfy {
                SendEntryUIProbe.element($0, in: host.rootView) != nil
            }
        }
        let ordinary = try #require(
            SendEntryUIProbe.element(ordinaryIdentifier, in: host.rootView)
        )
        let expectedValue = "\(WalletLocalization.string("wallet.creation.entropy.health.section")): \(WalletLocalization.string("wallet.creation.entropy.health.warning.dominance"))"

        for (identifier, label) in zip(
            flaggedIdentifiers,
            ["Die Result: 1", "Heads", "Random digit 7."]
        ) {
            let flagged = try #require(
                SendEntryUIProbe.element(identifier, in: host.rootView)
            )
            #expect(flagged.accessibilityLabel == label)
            #expect(flagged.accessibilityValue == expectedValue)
        }
        #expect(ordinary.accessibilityValue?.isEmpty != false)
    }

    @Test(arguments: [false, true], [NativeListTestLayout.phone, .pad, .phoneLandscape, .largeTextRTL])
    func infoUsesAdaptiveNativePresentation(switcher: Bool, layout: NativeListTestLayout) async throws {
        let state = EntropyInfoPopoverTestState()
        let assessment = SettingsWalletEntropyHealthAssessment(
            status: .warning(.dominance(method: .dice)),
            flaggedEntryIDs: []
        )
        let settings = WalletSettingsStore(
            database: try WalletDatabase.temporary()
        )
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                List {
                    SettingsWalletEntropyHealthSection(
                        assessment: assessment,
                        isShowingInfo: Binding(
                            get: { state.isPresented },
                            set: { state.isPresented = $0 }
                        )
                    ) {
                        if switcher {
                            WalletSwitcherEntropyInputInfoPopover(
                                assessment: assessment
                            )
                        } else {
                            OnboardingEntropyInputInfoPopover(
                                assessment: assessment
                            )
                        }
                    }
                }
            }
            .environment(settings)
        }
        defer {
            host.rootView.window?.rootViewController?.dismiss(animated: false)
            host.close()
        }
        _ = try await host.list()
        state.isPresented = true
        let root = try #require(host.rootView.window?.rootViewController)
        for _ in 0..<100 {
            host.rootView.layoutIfNeeded()
            await Task.yield()
            if let presented = root.presentedViewController, !presented.isBeingPresented { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let presented = try #require(root.presentedViewController)
        if layout.textSize.isAccessibilitySize {
            #expect(presented.modalPresentationStyle != .popover)
            #expect(presented.popoverPresentationController == nil)
            return
        }
        let popover = try #require(presented.popoverPresentationController)
        #expect(presented.modalPresentationStyle == .popover)
        #expect(popover.sourceView != nil)
        #expect(popover.sourceRect.width > 0 && popover.sourceRect.width < 100)
        #expect(popover.sourceRect.height > 0 && popover.sourceRect.height < 100)
        let frame = popover.frameOfPresentedViewInContainerView
        #expect(frame.width < host.rootView.bounds.width)
        // Native popovers shrink around their anchor in short landscape windows.
        #expect(frame.height > popover.sourceRect.height)
        #expect(presented.view.bounds.height > 0)
        #expect(frame.height <= host.rootView.bounds.height)
    }
}

private struct EntropyMethodSelectorTestHarness: View {
    @State private var selection = SettingsWalletEntropyMethod.dice

    var body: some View {
        SettingsWalletEntropyMethodSelector(
            selection: $selection,
            isDisabled: false
        )
        .padding(.vertical, 8)
    }
}

@MainActor
@Observable
private final class EntropyInfoPopoverTestState {
    var isPresented = false
}
