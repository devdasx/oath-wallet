import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
import WalletCore
@testable import Aperture

struct SettingsWalletEntropyTests {
    @Test
    func coinActionsUseConciseLocalizedLabels() {
        #expect(
            WalletLocalization.string(
                "wallet.creation.entropy.coin.heads"
            ) == "Heads"
        )
        #expect(
            WalletLocalization.string(
                "wallet.creation.entropy.coin.tails"
            ) == "Tails"
        )
    }

    @Test
    func digitGridUsesFiveColumnsAndTwoRows() {
        #expect(SettingsWalletEntropyDigitGrid.digitCount == 10)
        #expect(SettingsWalletEntropyDigitGrid.columnCount == 5)
        #expect(SettingsWalletEntropyDigitGrid.rowCount == 2)
    }

    @Test
    func diceFaceArtworkUsesCanonicalOneThroughSixAssetMapping() {
        for face in 1...6 {
            #expect(
                SettingsWalletEntropyDieArtwork.assetName(for: face)
                    == "EntropyDiceFace\(face)"
            )
        }

        #expect(
            SettingsWalletEntropyDieArtwork.assetName(for: 0) == nil
        )
        #expect(
            SettingsWalletEntropyDieArtwork.assetName(for: 7) == nil
        )
    }

    @Test
    func recentInputVisualsUseOneContinuousSingleRowList() throws {
        let entries = (0..<45).map { digit in
            SettingsWalletEntropyEntry(
                source: .digit(digit % 10),
                contributedBits: 1
            )
        }

        #expect(
            SettingsWalletEntropyRecentInputs.visibleRowCount == 1
        )
        #expect(SettingsWalletEntropyRecentInputs.entriesPerRow == 10)
        #expect(
            SettingsWalletEntropyRecentInputs.visibleEntryCapacity == 10
        )
        #expect(entries.count > 10)
        #expect(Set(entries.map(\.id)).count == entries.count)
        let lastEntry = try #require(entries.last)
        #expect(
            SettingsWalletEntropyRecentInputs.newestEntryID(from: entries)
                == lastEntry.id
        )

        #expect(
            SettingsWalletEntropyRecentInputs.newestEntryID(from: Array(entries.prefix(10)))
                == entries[9].id
        )
        #expect(
            SettingsWalletEntropyRecentInputs.newestEntryID(from: Array(entries.prefix(11)))
                == entries[10].id
        )
    }

    @Test
    func latestSourceTracksEveryMethodAndUndo() {
        var accumulator = SettingsWalletEntropyAccumulator()
        #expect(accumulator.latestSource == nil)

        let appendedDice = accumulator.appendDiceFace(4)
        #expect(appendedDice)
        #expect(accumulator.latestSource == .dice(face: 4))
        let firstDiceEntryID = accumulator.latestEntryID(
            for: .dice(face: 4)
        )
        #expect(firstDiceEntryID != nil)

        let appendedRepeatedDice = accumulator.appendDiceFace(4)
        #expect(appendedRepeatedDice)
        let repeatedDiceEntryID = accumulator.latestEntryID(
            for: .dice(face: 4)
        )
        #expect(repeatedDiceEntryID != nil)
        #expect(repeatedDiceEntryID != firstDiceEntryID)

        let appendedCoin = accumulator.appendCoinSide(.tails)
        #expect(appendedCoin)
        #expect(accumulator.latestSource == .coin(side: .tails))
        #expect(
            accumulator.latestEntryID(for: .dice(face: 4)) == nil
        )

        let appendedDigit = accumulator.appendDigit(7)
        #expect(appendedDigit)
        #expect(accumulator.latestSource == .digit(7))

        accumulator.undoLastEntry()
        #expect(accumulator.latestSource == .coin(side: .tails))

        accumulator.reset()
        #expect(accumulator.latestSource == nil)
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad])
    @MainActor
    func recentInputScrollsWhenOneEntryOverflowsTheSingleRow(
        layout: NativeListTestLayout
    ) async throws {
        let model = SettingsWalletEntropyRecentInputsTestModel(
            entries: entropyEntries(count: 10)
        )
        let host = try NativeListTestHost(layout: layout) {
            SettingsWalletEntropyRecentInputsTestHarness(
                model: model
            )
        }
        defer { host.close() }

        try await waitForInitialEntropyRecentInputLayout(in: host)

        model.entries.append(
            SettingsWalletEntropyEntry(
                source: .digit(1),
                contributedBits: 1
            )
        )

        let scrollView = try await waitForScrolledEntropyRecentInputs(
            in: host
        )
        #expect(scrollView.contentOffset.x > 0)
        #expect(scrollView.bounds.height <= 30)
        #expect(scrollView.contentSize.height <= scrollView.bounds.height + 1)
    }

    @Test
    func sixSidedDiceResultsContributeUnbiasedBits() throws {
        let expected = [
            (value: 0, bitCount: 2),
            (value: 1, bitCount: 2),
            (value: 2, bitCount: 2),
            (value: 3, bitCount: 2),
            (value: 0, bitCount: 1),
            (value: 1, bitCount: 1)
        ]

        for face in 1...6 {
            let contribution = try #require(
                SettingsWalletEntropyAccumulator.unbiasedContribution(
                    number: face - 1,
                    base: 6
                )
            )
            #expect(contribution.value == expected[face - 1].value)
            #expect(
                contribution.bitCount == expected[face - 1].bitCount
            )
        }
    }

    @Test
    func randomDigitsContributeUnbiasedBits() throws {
        for digit in 0...7 {
            let contribution = try #require(
                SettingsWalletEntropyAccumulator.unbiasedContribution(
                    number: digit,
                    base: 10
                )
            )
            #expect(contribution.value == digit)
            #expect(contribution.bitCount == 3)
        }

        let eight = try #require(
            SettingsWalletEntropyAccumulator.unbiasedContribution(
                number: 8,
                base: 10
            )
        )
        let nine = try #require(
            SettingsWalletEntropyAccumulator.unbiasedContribution(
                number: 9,
                base: 10
            )
        )
        #expect(eight.value == 0)
        #expect(eight.bitCount == 1)
        #expect(nine.value == 1)
        #expect(nine.bitCount == 1)
    }

    @Test
    func coinFlipsFillExactlyTwoHundredFiftySixBits() throws {
        var accumulator = SettingsWalletEntropyAccumulator()
        let expectedEntropy = Data([
            0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
            0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
            0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
            0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad
        ])

        for byte in expectedEntropy {
            for bitIndex in stride(from: 7, through: 0, by: -1) {
                let bit = (byte >> UInt8(bitIndex)) & 1
                let wasAppended = accumulator.appendCoinSide(
                    bit == 0 ? .heads : .tails
                )
                #expect(wasAppended)
            }
        }

        #expect(accumulator.bitCount == 256)
        #expect(accumulator.remainingBitCount == 0)
        #expect(accumulator.isComplete)
        #expect(accumulator.isReadyForWalletCreation)
        #expect(accumulator.entropyData == expectedEntropy)
        let appendedAfterCompletion = accumulator.appendCoinSide(.heads)
        #expect(!appendedAfterCompletion)
    }

    @Test
    func healthAnalyzerUsesExactBinomialUpperTail() {
        #expect(
            abs(
                SettingsWalletEntropyHealthAnalyzer.binomialUpperTail(
                    trials: 3,
                    successesAtLeast: 3,
                    successProbability: 0.5
                ) - 0.125
            ) < 0.000_000_001
        )
        #expect(
            abs(
                SettingsWalletEntropyHealthAnalyzer.binomialUpperTail(
                    trials: 3,
                    successesAtLeast: 2,
                    successProbability: 0.5
                ) - 0.5
            ) < 0.000_000_001
        )
        #expect(
            SettingsWalletEntropyHealthAnalyzer.binomialUpperTail(
                trials: 3,
                successesAtLeast: 0,
                successProbability: 0.5
            ) == 1
        )
        #expect(
            SettingsWalletEntropyHealthAnalyzer.binomialUpperTail(
                trials: 3,
                successesAtLeast: 4,
                successProbability: 0.5
            ) == 0
        )
    }

    @Test
    func repeatedCoinResultStopsInputUntilUserRepairsIt() {
        var accumulator = SettingsWalletEntropyAccumulator()

        while !accumulator.healthAssessment.requiresIntervention {
            #expect(accumulator.entries.count < 256)
            let wasAppended = accumulator.appendCoinSide(.heads)
            #expect(wasAppended)
        }

        guard case .warning(.repetition(method: .coin)) =
            accumulator.healthAssessment.status
        else {
            Issue.record("Expected a repeated-coin warning")
            return
        }
        let warningEntryCount = accumulator.entries.count
        #expect(!accumulator.healthAssessment.flaggedEntryIDs.isEmpty)
        let appendedDuringWarning = accumulator.appendCoinSide(.tails)
        #expect(!appendedDuringWarning)
        #expect(accumulator.entries.count == warningEntryCount)
        #expect(!accumulator.isReadyForWalletCreation)

        accumulator.undoLastEntry()
        #expect(!accumulator.healthAssessment.requiresIntervention)
        let appendedAfterUndo = accumulator.appendCoinSide(.tails)
        #expect(appendedAfterUndo)

        accumulator.reset()
        #expect(accumulator.entries.isEmpty)
        #expect(accumulator.healthAssessment.status == .monitoring)
    }

    @Test(arguments: [
        (SettingsWalletEntropyHealthAssessment.Status.monitoring, "wallet.creation.entropy.health.monitoring", "wallet.creation.entropy.health.info.message"),
        (.noWarningSigns, "wallet.creation.entropy.health.monitoring", "wallet.creation.entropy.health.info.message"),
        (.warning(.repetition(method: .dice)), "wallet.creation.entropy.health.warning.repetition", "wallet.creation.entropy.health.warning.fix"),
        (.warning(.dominance(method: .coin)), "wallet.creation.entropy.health.warning.dominance", "wallet.creation.entropy.health.warning.fix"),
        (.warning(.predictablePattern(method: .digits)), "wallet.creation.entropy.health.warning.pattern", "wallet.creation.entropy.health.warning.fix")
    ])
    func informationExplainsCurrentAssessment(status: SettingsWalletEntropyHealthAssessment.Status, summary: String, guidance: String) {
        let assessment = SettingsWalletEntropyHealthAssessment(status: status, flaggedEntryIDs: [])
        #expect(assessment.informationSummaryKey == summary)
        #expect(assessment.informationGuidanceKey == guidance)
    }

    @Test
    func predictableCyclesAreDetectedForEveryInputMethod() {
        let cases: [(
            SettingsWalletEntropyMethod,
            [SettingsWalletEntropyEntry]
        )] = [
            (
                .coin,
                (0..<40).map {
                    SettingsWalletEntropyEntry(
                        source: .coin(
                            side: $0.isMultiple(of: 2) ? .heads : .tails
                        ),
                        contributedBits: 1
                    )
                }
            ),
            (
                .dice,
                (0..<24).map {
                    SettingsWalletEntropyEntry(
                        source: .dice(face: ($0 % 6) + 1),
                        contributedBits: 1
                    )
                }
            ),
            (
                .digits,
                (0..<20).map {
                    SettingsWalletEntropyEntry(
                        source: .digit($0 % 10),
                        contributedBits: 1
                    )
                }
            )
        ]

        for (method, entries) in cases {
            let assessment = SettingsWalletEntropyHealthAnalyzer.assess(
                entries: entries
            )
            #expect(
                assessment.status
                    == .warning(.predictablePattern(method: method))
            )
            #expect(!assessment.flaggedEntryIDs.isEmpty)

            let repeatedSource: SettingsWalletEntropySource = switch method {
            case .coin: .coin(side: .heads)
            case .dice: .dice(face: 1)
            case .digits: .digit(0)
            }
            let repetitionAssessment =
                SettingsWalletEntropyHealthAnalyzer.assess(
                    entries: (0..<40).map { _ in
                        SettingsWalletEntropyEntry(
                            source: repeatedSource,
                            contributedBits: 1
                        )
                    }
                )
            #expect(repetitionAssessment.requiresIntervention)
        }
    }

    @Test
    func extremeDominanceIsDetectedWithoutARepeatedRun() {
        let symbols =
            "100000100010000011110010000011010100001000100100011000010000101000000000000001111100001110100011100001000010100000100000000100100011000000000001000110010010000000000010000000"
        let entries = symbols.map { symbol in
            SettingsWalletEntropyEntry(
                source: .coin(side: symbol == "0" ? .heads : .tails),
                contributedBits: 1
            )
        }
        let assessment = SettingsWalletEntropyHealthAnalyzer.assess(
            entries: entries
        )

        #expect(assessment.status == .warning(.dominance(method: .coin)))
        #expect(!assessment.flaggedEntryIDs.isEmpty)
    }

    @Test
    func switchingMethodsCannotHideAWeakSource() {
        let entries = (0..<11).flatMap { index in
            [
                SettingsWalletEntropyEntry(
                    source: .digit(0),
                    contributedBits: 1
                ),
                SettingsWalletEntropyEntry(
                    source: .coin(
                        side: index.isMultiple(of: 2) ? .heads : .tails
                    ),
                    contributedBits: 1
                )
            ]
        }
        let assessment = SettingsWalletEntropyHealthAnalyzer.assess(
            entries: entries
        )

        guard case let .warning(issue) = assessment.status else {
            Issue.record("Expected the repeated digit source to be rejected")
            return
        }
        switch issue {
        case .repetition(method: .digits),
             .dominance(method: .digits):
            break
        default:
            Issue.record("Expected a digit-source warning")
        }
    }

    @Test
    func undoAndResetRemoveOnlyRecordedContributions() {
        var accumulator = SettingsWalletEntropyAccumulator()
        let appendedDice = accumulator.appendDiceFace(1)
        let appendedCoin = accumulator.appendCoinSide(.tails)
        #expect(appendedDice)
        #expect(appendedCoin)
        #expect(accumulator.bitCount == 3)

        accumulator.undoLastEntry()
        #expect(accumulator.bitCount == 2)
        #expect(accumulator.entries.count == 1)

        accumulator.reset()
        #expect(accumulator.bitCount == 0)
        #expect(accumulator.entries.isEmpty)
        #expect(accumulator.entropyData == nil)
    }

    @Test
    func walletCoreCreatesOfficialTwentyFourWordZeroVector() throws {
        let passphrase = "Aperture passphrase"
        let draft = try WalletCoreService.generateEVMWallet(
            entropy: Data(repeating: 0, count: 32),
            passphrase: passphrase
        )
        let expectedWords = Array(
            repeating: "abandon",
            count: 23
        ) + ["art"]

        #expect(draft.words == expectedWords)
        #expect(draft.mnemonic == expectedWords.joined(separator: " "))
        #expect(draft.words.count == 24)
        #expect(BIP39Mnemonic.isValid(draft.mnemonic))
        #expect(draft.passphrase == passphrase)
        #expect(!draft.address.isEmpty)
    }

    @Test
    func customEntropyWalletPersistsWithAndWithoutPassphrase()
        async throws
    {
        try await assertCustomEntropyWalletPersists(passphrase: "")
        try await assertCustomEntropyWalletPersists(
            passphrase: "Aperture entropy passphrase"
        )
    }

    @Test
    func passphrasePersistsForEveryPermittedMnemonicWordCount()
        async throws
    {
        let passphrase = "Aperture all-length passphrase"
        let entropyByteCounts = [
            12: 16,
            15: 20,
            18: 24,
            21: 28,
            24: 32
        ]

        for wordCount in BIP39Mnemonic.permittedWordCounts {
            let entropyByteCount = try #require(
                entropyByteCounts[wordCount]
            )
            let sourceWallet = try #require(
                HDWallet(
                    entropy: Data(
                        repeating: UInt8(wordCount),
                        count: entropyByteCount
                    ),
                    passphrase: ""
                )
            )
            let validation = try #require(
                BIP39Mnemonic.validation(of: sourceWallet.mnemonic)
            )
            #expect(validation.wordCount == wordCount)

            let createdDraft = try WalletCoreService.restoreEVMWallet(
                mnemonic: validation.normalizedPhrase,
                passphrase: passphrase
            )
            let draftWithoutPassphrase = try WalletCoreService
                .restoreEVMWallet(
                    mnemonic: validation.normalizedPhrase
                )
            #expect(createdDraft.words.count == wordCount)
            #expect(createdDraft.passphrase == passphrase)
            #expect(createdDraft.address != draftWithoutPassphrase.address)
            try await assertCreatedWalletPersists(
                draft: createdDraft,
                expectedWordCount: wordCount,
                expectedPassphrase: passphrase
            )

            let importedDraft = try WalletCoreService
                .importRecoveryPhrase(
                    validation.normalizedPhrase,
                    passphrase: passphrase
                )
            try await assertImportedWalletPersists(
                draft: importedDraft,
                expectedWordCount: wordCount,
                expectedPassphrase: passphrase
            )
        }
    }

    @Test
    func walletCoreRejectsEntropyThatIsNotTwoHundredFiftySixBits() {
        #expect(throws: WalletCoreServiceError.self) {
            try WalletCoreService.generateEVMWallet(
                entropy: Data(repeating: 0, count: 31)
            )
        }
    }

    @Test
    func entropyEventUniversalLinkOpensPhysicalEntropy() throws {
        let canonicalURL = try #require(
            URL(string: "https://aperturex.io/app/create-wallet/entropy")
        )
        let trailingURL = try #require(
            URL(
                string: "https://aperturex.io/app/create-wallet/entropy/?source=app-store-event"
            )
        )

        #expect(
            WalletAppDeepLinkParser.destination(for: canonicalURL)
                == .physicalEntropy
        )
        #expect(
            WalletAppDeepLinkParser.destination(for: trailingURL)
                == .physicalEntropy
        )
    }

    @Test
    func entropyEventUniversalLinkRejectsOtherDestinations() throws {
        let insecureURL = try #require(
            URL(string: "http://aperturex.io/app/create-wallet/entropy")
        )
        let unrelatedURL = try #require(
            URL(string: "https://aperturex.io/app/create-wallet")
        )
        let otherHostURL = try #require(
            URL(string: "https://example.com/app/create-wallet/entropy")
        )

        #expect(WalletAppDeepLinkParser.destination(for: insecureURL) == nil)
        #expect(WalletAppDeepLinkParser.destination(for: unrelatedURL) == nil)
        #expect(WalletAppDeepLinkParser.destination(for: otherHostURL) == nil)
    }

    @Test
    func entropyEventCustomURLOpensPhysicalEntropy() throws {
        let canonicalURL = try #require(
            URL(string: "aperturewallet://create-wallet/entropy")
        )
        let campaignURL = try #require(
            URL(
                string: "aperturewallet://create-wallet/entropy/?source=app-store-event"
            )
        )

        #expect(
            WalletAppDeepLinkParser.destination(for: canonicalURL)
                == .physicalEntropy
        )
        #expect(
            WalletAppDeepLinkParser.destination(for: campaignURL)
                == .physicalEntropy
        )
    }

    @Test
    func entropyEventCustomURLRejectsOtherDestinations() throws {
        let genericScheme = try #require(
            URL(string: "aperture://create-wallet/entropy")
        )
        let unrelatedHost = try #require(
            URL(string: "aperturewallet://remove-wallet/entropy")
        )
        let unrelatedPath = try #require(
            URL(string: "aperturewallet://create-wallet/private-key")
        )

        #expect(WalletAppDeepLinkParser.destination(for: genericScheme) == nil)
        #expect(WalletAppDeepLinkParser.destination(for: unrelatedHost) == nil)
        #expect(WalletAppDeepLinkParser.destination(for: unrelatedPath) == nil)
    }

    @Test
    func agentUniversalLinksMapOnlyToSafeForegroundDestinations()
        throws {
        let routes: [(String, WalletAppDeepLinkDestination)] = [
            ("/app/search", .universalSearch),
            ("/app/receive", .receive),
            ("/app/tools/currency-converter", .currencyConverter),
            ("/app/settings/security", .securitySettings),
            ("/app/settings/wallets", .walletManagement)
        ]

        for (path, destination) in routes {
            let canonicalURL = try #require(
                URL(string: "https://aperturex.io\(path)")
            )
            let attributedURL = try #require(
                URL(
                    string:
                        "https://APERTUREX.IO\(path)/?source=app-intent"
                )
            )
            #expect(
                WalletAppDeepLinkParser.destination(for: canonicalURL)
                    == destination
            )
            #expect(
                WalletAppDeepLinkParser.destination(for: attributedURL)
                    == destination
            )
            #expect(destination.universalURL == canonicalURL)
        }
    }

    @Test
    func agentCustomURLsMapOnlyToSafeForegroundDestinations() throws {
        let routes: [(String, WalletAppDeepLinkDestination)] = [
            ("aperturewallet://search", .universalSearch),
            ("aperturewallet://receive", .receive),
            (
                "aperturewallet://tools/currency-converter",
                .currencyConverter
            ),
            (
                "aperturewallet://settings/security",
                .securitySettings
            ),
            (
                "aperturewallet://settings/wallets",
                .walletManagement
            )
        ]

        for (rawURL, destination) in routes {
            let url = try #require(URL(string: rawURL))
            #expect(
                WalletAppDeepLinkParser.destination(for: url)
                    == destination
            )
        }
    }

    @Test
    func agentDeepLinksRejectUnsafeOrAmbiguousURLs() throws {
        let rejectedURLs = try [
            "https://aperturex.io/app/send",
            "https://aperturex.io/app/sign",
            "https://aperturex.io/app/export-recovery-phrase",
            "https://user@aperturex.io/app/search",
            "https://aperturex.io:443/app/search",
            "http://aperturex.io/app/search",
            "https://www.aperturex.io/app/search",
            "aperturewallet://send",
            "aperturewallet:///search"
        ].map { rawURL in
            try #require(URL(string: rawURL))
        }

        for url in rejectedURLs {
            #expect(WalletAppDeepLinkParser.destination(for: url) == nil)
        }
    }

    @Test
    func agentDeepLinkPresentationNeverBypassesWalletProtection() {
        let ready = WalletAgentDeepLinkPresentationContext(
            requestID: UUID(),
            walletIsVisible: true,
            sceneIsActive: true,
            walletIsRestricted: false,
            hasBlockingPresentation: false
        )
        #expect(ready.canPresent)

        let blockedContexts = [
            WalletAgentDeepLinkPresentationContext(
                requestID: nil,
                walletIsVisible: true,
                sceneIsActive: true,
                walletIsRestricted: false,
                hasBlockingPresentation: false
            ),
            WalletAgentDeepLinkPresentationContext(
                requestID: UUID(),
                walletIsVisible: false,
                sceneIsActive: true,
                walletIsRestricted: false,
                hasBlockingPresentation: false
            ),
            WalletAgentDeepLinkPresentationContext(
                requestID: UUID(),
                walletIsVisible: true,
                sceneIsActive: false,
                walletIsRestricted: false,
                hasBlockingPresentation: false
            ),
            WalletAgentDeepLinkPresentationContext(
                requestID: UUID(),
                walletIsVisible: true,
                sceneIsActive: true,
                walletIsRestricted: true,
                hasBlockingPresentation: false
            ),
            WalletAgentDeepLinkPresentationContext(
                requestID: UUID(),
                walletIsVisible: true,
                sceneIsActive: true,
                walletIsRestricted: false,
                hasBlockingPresentation: true
            )
        ]
        #expect(blockedContexts.allSatisfy { !$0.canPresent })
    }

    @Test
    func appIntentsOpenOnlyTheirDeclaredUniversalLinks() {
        #expect(
            ApertureSearchWalletIntent.destination.universalURL
                == WalletAppDeepLinkParser.universalSearchURL
        )
        #expect(
            ApertureReceiveCryptoIntent.destination.universalURL
                == WalletAppDeepLinkParser.receiveURL
        )
        #expect(
            ApertureCurrencyConverterIntent.destination.universalURL
                == WalletAppDeepLinkParser.currencyConverterURL
        )
        #expect(
            ApertureSecuritySettingsIntent.destination.universalURL
                == WalletAppDeepLinkParser.securitySettingsURL
        )
        #expect(
            ApertureWalletManagementIntent.destination.universalURL
                == WalletAppDeepLinkParser.walletManagementURL
        )
        #expect(
            AperturePhysicalEntropyWalletIntent.destination.universalURL
                == WalletAppDeepLinkParser.entropyWalletCreationURL
        )
    }

    @Test
    func entropyEventRequiresPasscodeOnlyWhenProfileHasNone()
        async throws
    {
        let database = try WalletDatabase.temporary()

        #expect(
            try await database.entropyEventCreationSecurityMode()
                == .requirePasscodeSetup
        )
    }

    private func assertCustomEntropyWalletPersists(
        passphrase: String
    ) async throws {
        let draft = try WalletCoreService.generateEVMWallet(
            entropy: Data(repeating: 0, count: 32),
            passphrase: passphrase
        )
        try await assertCreatedWalletPersists(
            draft: draft,
            expectedWordCount: 24,
            expectedPassphrase: passphrase
        )
    }

    private func entropyEntries(
        count: Int
    ) -> [SettingsWalletEntropyEntry] {
        (0..<count).map { index in
            SettingsWalletEntropyEntry(
                source: .digit(index % 10),
                contributedBits: 1
            )
        }
    }

    @MainActor
    private func waitForInitialEntropyRecentInputLayout(
        in host: NativeListTestHost
    ) async throws {
        for _ in 0..<100 {
            host.rootView.layoutIfNeeded()
            if entropyRecentInputScrollView(in: host.rootView) != nil {
                return
            }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Recent entropy inputs did not finish laying out")
    }

    @MainActor
    private func waitForScrolledEntropyRecentInputs(
        in host: NativeListTestHost
    ) async throws -> UIScrollView {
        for _ in 0..<100 {
            host.rootView.layoutIfNeeded()
            if let scrollView = entropyRecentInputScrollView(
                in: host.rootView
            ), scrollView.contentSize.width > scrollView.bounds.width + 1,
               scrollView.contentOffset.x > 0
            {
                return scrollView
            }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(20))
        }

        let scrollView = try #require(
            entropyRecentInputScrollView(in: host.rootView)
        )
        #expect(
            scrollView.contentSize.width > scrollView.bounds.width + 1,
            "The 11th input should make the single row immediately scrollable"
        )
        #expect(
            scrollView.contentOffset.x > 0,
            "A new input should become visible without waiting for another input"
        )
        return scrollView
    }

    @MainActor
    private func entropyRecentInputScrollView(
        in view: UIView
    ) -> UIScrollView? {
        if let scrollView = view as? UIScrollView,
           scrollView.bounds.height > 0,
           scrollView.bounds.height < 100,
           scrollView.bounds.width > 0
        {
            return scrollView
        }

        for subview in view.subviews {
            if let scrollView = entropyRecentInputScrollView(
                in: subview
            ) {
                return scrollView
            }
        }
        return nil
    }

    private func assertCreatedWalletPersists(
        draft: WalletCreationDraft,
        expectedWordCount: Int,
        expectedPassphrase: String
    ) async throws {
        let database = try WalletDatabase.temporary()
        let identity = try await database.persistCreatedWallet(
            draft: draft,
            security: .reuseExistingProfile
        )
        try await assertStoredCredential(
            walletID: identity.walletID,
            database: database,
            expectedMnemonic: draft.mnemonic,
            expectedWordCount: expectedWordCount,
            expectedPassphrase: expectedPassphrase
        )
    }

    private func assertImportedWalletPersists(
        draft: WalletImportDraft,
        expectedWordCount: Int,
        expectedPassphrase: String
    ) async throws {
        let database = try WalletDatabase.temporary()
        let identity = try await database.persistImportedWallet(
            draft: draft,
            security: .reuseExistingProfile
        )
        guard case let .recoveryPhrase(mnemonic, _, _) = draft.secret
        else {
            Issue.record("Expected a recovery-phrase import draft")
            return
        }
        try await assertStoredCredential(
            walletID: identity.walletID,
            database: database,
            expectedMnemonic: mnemonic,
            expectedWordCount: expectedWordCount,
            expectedPassphrase: expectedPassphrase
        )
    }

    private func assertStoredCredential(
        walletID: String,
        database: WalletDatabase,
        expectedMnemonic: String,
        expectedWordCount: Int,
        expectedPassphrase: String
    ) async throws {
        let wallet = try await database.pool.read { database in
            guard let wallet = try DBWalletRecord.fetchOne(
                database,
                key: walletID
            ) else {
                throw WalletCreationPersistenceError.missingSecret
            }
            return wallet
        }
        let reference = try #require(wallet.secretKeyReference)
        defer {
            try? WalletSecretVault.shared.deleteIfPresent(
                reference: reference
            )
        }
        let credential = try WalletRecoveryCredential.decode(
            WalletSecretVault.shared.data(reference: reference)
        )

        #expect(wallet.mnemonicWordCount == expectedWordCount)
        #expect(credential.mnemonic == expectedMnemonic)
        #expect(credential.passphrase == expectedPassphrase)
        #expect(credential.wordCount == expectedWordCount)
    }
}

@MainActor
private final class SettingsWalletEntropyRecentInputsTestModel:
    ObservableObject
{
    @Published var entries: [SettingsWalletEntropyEntry]

    init(entries: [SettingsWalletEntropyEntry]) {
        self.entries = entries
    }
}

private struct SettingsWalletEntropyRecentInputsTestHarness: View {
    @ObservedObject var model:
        SettingsWalletEntropyRecentInputsTestModel

    var body: some View {
        SettingsWalletEntropyRecentInputs(
            entries: model.entries,
            assessment: SettingsWalletEntropyHealthAssessment(
                status: .monitoring,
                flaggedEntryIDs: []
            )
        )
            .frame(width: 300)
    }
}
