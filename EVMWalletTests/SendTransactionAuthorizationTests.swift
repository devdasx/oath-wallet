import Foundation
import GRDB
import Testing
@testable import Aperture

@Suite(.serialized)
struct SendTransactionAuthorizationTests {
    @Test
    func signingAuthorizationIsSingleUseThroughResolver()
        async throws
    {
        let fixture = try await makeFixture()
        defer { fixture.removeSecret() }
        let authorization = try await issueAuthorization(
            fixture: fixture
        )
        let copiedAuthorization = authorization
        let resolver = SendSigningKeyResolver(
            database: fixture.database
        )

        let material = try await resolver.resolve(
            draft: fixture.draft,
            authorization: authorization
        )
        #expect(material.walletID == fixture.walletID)
        #expect(material.account.id == fixture.account.id)
        #expect(!material.privateKey.isEmpty)

        await #expect(
            throws: SendTransactionSubmissionError.authorizationExpired
        ) {
            _ = try await resolver.resolve(
                draft: fixture.draft,
                authorization: copiedAuthorization
            )
        }
    }

    @Test
    func persistedBitcoinHDChildCanAuthorizeAfterAccountRowAdvances()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(
            service: "send-bitcoin-child-authorization-tests.\(UUID().uuidString)"
        )
        defer { try? vault.deleteAll() }
        let creation = try WalletCoreService.restoreEVMWallet(
            mnemonic: WalletCredentialTestFixtures.recoveryPhrase()
        )
        let imported = WalletImportDraft(
            secret: .recoveryPhrase(
                mnemonic: creation.mnemonic,
                passphrase: creation.passphrase,
                wordCount: creation.words.count
            ),
            address: creation.address,
            normalizedAddress: creation.normalizedAddress,
            derivationPath: creation.derivationPath,
            publicKey: creation.publicKey
        )
        let identity = try await database.persistImportedWallet(
            draft: imported,
            security: .reuseExistingProfile,
            vault: vault
        )
        _ = try await database.ensureBitcoinHDWallet(
            walletID: identity.walletID,
            vault: vault
        )
        let accounts = try await WalletDataStore(database: database)
            .accounts(walletID: identity.walletID)
        let account = try #require(accounts.first {
            $0.networkID == BitcoinFamilyChain.bitcoin.networkID
        })
        let addresses = try await database.bitcoinHDAddresses(
            walletID: identity.walletID,
            addressType: .bip86,
            branch: .external
        )
        let source = try #require(addresses.first {
            $0.derived.index == 7
        })
        let recipient = try #require(addresses.first {
            $0.derived.index == 8
        })
        #expect(source.derived.address != account.address)
        let draft = Self.bitcoinAuthorizationDraft(
            sourceAddress: source.derived.address,
            recipient: recipient.derived.address
        )

        let route = try await SendAuthorizationRouter(
            database: database
        ).prepare(for: draft)
        guard case let .authorized(authorization) = route else {
            Issue.record(
                "A persisted Bitcoin HD child must bind to its wallet account."
            )
            return
        }
        _ = try await authorization.consume(
            reviewedDraft: draft,
            walletID: identity.walletID,
            accountID: account.id,
            networkID: BitcoinFamilyChain.bitcoin.networkID
        )
    }

    @Test
    func reviewedDraftMutationIsRejectedAndConsumesTheGrant()
        async throws
    {
        let fixture = try await makeFixture()
        defer { fixture.removeSecret() }
        let authorization = try await issueAuthorization(
            fixture: fixture
        )
        let changedDraft = fixture.draft.replacing(
            recipient:
                "0x0000000000000000000000000000000000000002",
            amount: "1",
            note: nil
        )

        await #expect(
            throws: SendTransactionAuthorizationError.bindingMismatch
        ) {
            _ = try await authorization.consume(
                reviewedDraft: changedDraft,
                walletID: fixture.walletID,
                accountID: fixture.account.id,
                networkID: fixture.account.networkID
            )
        }
        await #expect(
            throws: SendTransactionAuthorizationError.alreadyConsumed
        ) {
            _ = try await authorization.consume(
                reviewedDraft: fixture.draft,
                walletID: fixture.walletID,
                accountID: fixture.account.id,
                networkID: fixture.account.networkID
            )
        }
    }

    @Test
    func walletAccountAndNetworkBindingsAreEnforced() async throws {
        let fixture = try await makeFixture()
        defer { fixture.removeSecret() }

        let wrongWallet = try await issueAuthorization(
            fixture: fixture
        )
        await #expect(
            throws: SendTransactionAuthorizationError.bindingMismatch
        ) {
            _ = try await wrongWallet.consume(
                reviewedDraft: fixture.draft,
                walletID: "different-wallet",
                accountID: fixture.account.id,
                networkID: fixture.account.networkID
            )
        }

        let wrongAccount = try await issueAuthorization(
            fixture: fixture
        )
        await #expect(
            throws: SendTransactionAuthorizationError.bindingMismatch
        ) {
            _ = try await wrongAccount.consume(
                reviewedDraft: fixture.draft,
                walletID: fixture.walletID,
                accountID: "different-account",
                networkID: fixture.account.networkID
            )
        }

        let wrongNetwork = try await issueAuthorization(
            fixture: fixture
        )
        await #expect(
            throws: SendTransactionAuthorizationError.bindingMismatch
        ) {
            _ = try await wrongNetwork.consume(
                reviewedDraft: fixture.draft,
                walletID: fixture.walletID,
                accountID: fixture.account.id,
                networkID: "polygon"
            )
        }
    }

    @Test
    func canonicalDigestCoversReviewedTransactionOptions() throws {
        let draft = Self.authorizationDraft(
            sourceAddress:
                "0x0000000000000000000000000000000000000001"
        )
        let changedAmount = draft.replacing(
            recipient: draft.recipient,
            amount: "2",
            note: draft.note
        )
        let changedFee = draft.replacingFeePolicy(
            SendNetworkFeePolicy.preset(.economy)
        )
        let changedPreparedFee = draft.replacingPreparedNetworkFee(
            SendResolvedNetworkFee(
                model: .evmEIP1559,
                primaryValue: "42000000000",
                secondaryValue: "2000000000"
            )
        )
        let changedNote = draft.replacingNote("Different note")
        let firstCustomBudget = draft.replacingFeePolicy(
            .custom(
                SendNetworkFeeCustomValue(
                    model: .evmEIP1559,
                    primaryValue: "100",
                    secondaryValue: "10",
                    totalBudgetAtomic: "2100000"
                )
            )
        )
        let changedCustomBudget = draft.replacingFeePolicy(
            .custom(
                SendNetworkFeeCustomValue(
                    model: .evmEIP1559,
                    primaryValue: "100",
                    secondaryValue: "10",
                    totalBudgetAtomic: "2100001"
                )
            )
        )

        let digest = try SendReviewedDraftDigest.make(draft)
        let identicalDigest = try SendReviewedDraftDigest.make(draft)
        let changedAmountDigest = try SendReviewedDraftDigest.make(
            changedAmount
        )
        let changedFeeDigest = try SendReviewedDraftDigest.make(
            changedFee
        )
        let changedPreparedFeeDigest = try SendReviewedDraftDigest.make(
            changedPreparedFee
        )
        let changedNoteDigest = try SendReviewedDraftDigest.make(
            changedNote
        )
        let firstCustomBudgetDigest = try SendReviewedDraftDigest.make(
            firstCustomBudget
        )
        let changedCustomBudgetDigest = try SendReviewedDraftDigest.make(
            changedCustomBudget
        )
        #expect(digest == identicalDigest)
        #expect(digest != changedAmountDigest)
        #expect(digest != changedFeeDigest)
        #expect(digest != changedPreparedFeeDigest)
        #expect(digest != changedNoteDigest)
        #expect(firstCustomBudgetDigest != changedCustomBudgetDigest)
    }

    @Test
    func canonicalDigestBindsExactOPReturnMessage() throws {
        let base = Self.bitcoinAuthorizationDraft(
            sourceAddress:
                "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh",
            recipient:
                "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
        )
        let first = base.replacingBitcoinFamilyOptions(
            .automatic.replacingOPReturnMessage("exact bytes")
        )
        let changed = base.replacingBitcoinFamilyOptions(
            .automatic.replacingOPReturnMessage("exact bytes ")
        )

        #expect(
            try SendReviewedDraftDigest.make(first)
                != SendReviewedDraftDigest.make(changed)
        )
    }

    @Test
    @MainActor
    func biometricSuccessIssuesAuthorizationBeforePasscodePresentation()
        async throws
    {
        let fixture = try await makeFixture()
        defer { fixture.removeSecret() }
        let passcodeReference = try await enableBiometrics(
            database: fixture.database
        )
        defer {
            try? WalletSecretVault.shared.deletePasscodeCredential(
                reference: passcodeReference
            )
        }

        let outcome = try await SendAuthorizationRouter(
            database: fixture.database,
            authenticationAction: { settings in
                WalletAuthenticationAction.resolveBiometricResult(
                    .success(()),
                    settings: settings
                )
            }
        ).prepare(for: fixture.draft)

        guard case let .authorized(authorization) = outcome else {
            Issue.record(
                "Successful Face ID must authorize before navigation."
            )
            return
        }
        let material = try await SendSigningKeyResolver(
            database: fixture.database
        ).resolve(
            draft: fixture.draft,
            authorization: authorization
        )
        #expect(material.walletID == fixture.walletID)
    }

    @Test
    @MainActor
    func biometricFailureRoutesToPasscodeWithTheRealFailure() async throws {
        let fixture = try await makeFixture()
        defer { fixture.removeSecret() }
        let passcodeReference = try await enableBiometrics(
            database: fixture.database
        )
        defer {
            try? WalletSecretVault.shared.deletePasscodeCredential(
                reference: passcodeReference
            )
        }

        let outcome = try await SendAuthorizationRouter(
            database: fixture.database,
            authenticationAction: { settings in
                WalletAuthenticationAction.resolveBiometricResult(
                    .failure(.unsuccessful),
                    settings: settings
                )
            }
        ).prepare(for: fixture.draft)

        guard case let .requiresPasscode(initialErrorKey) = outcome else {
            Issue.record("Failed Face ID must open passcode fallback.")
            return
        }
        #expect(
            initialErrorKey ==
                "security.authentication.biometric.error"
        )
    }

    @Test
    @MainActor
    func faceIDSuccessWaitsUntilTheSystemUIFinishesDismissing()
        async throws
    {
        let fixture = try await makeFixture()
        defer { fixture.removeSecret() }
        let authorization = try await issueAuthorization(
            fixture: fixture
        )
        var state = SendAuthorizationNavigationState()
        let initialResetID = state.reviewResetID
        let pendingRequestID = state.beginAuthorization()
        let requestID = try #require(pendingRequestID)

        state.receive(
            .authorized(authorization),
            context: Self.reviewContext(fixture.draft),
            requestID: requestID,
            sceneIsActive: false
        )

        #expect(!state.isAuthorizing)
        #expect(state.reviewResetID == initialResetID, "Successful Face ID must preserve the completed slider")
        #expect(state.takePendingPresentation(sceneIsActive: false) == nil)
        state.resumeAfterInactive()
        guard let presentation = state.takePendingPresentation(),
              case let .broadcast(context, routedAuthorization) =
                presentation else {
            Issue.record(
                "Face ID success must publish Transaction after reactivation."
            )
            return
        }
        #expect(context.sourceRouteDraft == fixture.draft)
        #expect(context.reviewedDraft == fixture.draft)
        #expect(routedAuthorization == authorization)
        state.resumeAfterInactive()
        #expect(state.takePendingPresentation() == nil)
    }

    @Test
    func faceIDFailureWaitsForTheActiveSceneBeforePasscodeSheet()
        throws
    {
        let draft = Self.authorizationDraft(
            sourceAddress:
                "0x0000000000000000000000000000000000000001"
        )
        var state = SendAuthorizationNavigationState()
        let pendingRequestID = state.beginAuthorization()
        let requestID = try #require(pendingRequestID)

        state.receive(
            .requiresPasscode(
                initialErrorKey:
                    "security.authentication.biometric.error"
            ),
            context: Self.reviewContext(draft),
            requestID: requestID,
            sceneIsActive: false
        )

        #expect(state.takePendingPresentation() == nil)

        state.resumeAfterInactive()

        guard let presentation = state.takePendingPresentation(),
              case let .passcode(context, initialErrorKey) =
                presentation else {
            Issue.record(
                "Failed Face ID must publish passcode after reactivation."
            )
            return
        }
        #expect(context.sourceRouteDraft == draft)
        #expect(context.reviewedDraft == draft)
        #expect(
            initialErrorKey ==
                "security.authentication.biometric.error"
        )
    }

    @Test
    func dogecoinPreparedFeeStillPresentsPasscodeFromCurrentReview()
        throws
    {
        let sourceDraft = Self.dogecoinReviewDraft()
        let reviewedDraft = sourceDraft.replacingPreparedNetworkFee(
            SendResolvedNetworkFee(
                model: .utxoPerVByte,
                primaryValue: "2",
                secondaryValue: nil
            )
        )
        let context = SendAuthorizationReviewContext(
            sourceRouteDraft: sourceDraft,
            reviewedDraft: reviewedDraft
        )
        var state = SendAuthorizationNavigationState()
        let pendingRequestID = state.beginAuthorization()
        let requestID = try #require(pendingRequestID)

        #expect(sourceDraft != reviewedDraft)
        state.receive(
            .requiresPasscode(initialErrorKey: nil),
            context: context,
            requestID: requestID,
            sceneIsActive: true
        )

        guard let presentation = state.takePendingPresentation(),
              case let .passcode(routedContext, initialErrorKey) =
                presentation else {
            Issue.record(
                "A reviewed fee must not silently discard passcode routing."
            )
            return
        }
        #expect(initialErrorKey == nil)
        #expect(routedContext == context)
        #expect(
            routedContext.isCurrent(
                in: [.review(sourceDraft)]
            )
        )
    }

    @Test
    func backgroundInvalidatesAnInFlightFaceIDNavigationRequest()
        throws
    {
        let draft = Self.authorizationDraft(
            sourceAddress:
                "0x0000000000000000000000000000000000000001"
        )
        var state = SendAuthorizationNavigationState()
        let pendingRequestID = state.beginAuthorization()
        let requestID = try #require(pendingRequestID)

        state.invalidateForBackground()
        state.receive(
            .requiresPasscode(initialErrorKey: nil),
            context: Self.reviewContext(draft),
            requestID: requestID,
            sceneIsActive: true
        )

        #expect(!state.isAuthorizing)
        #expect(state.activeRequestID == nil)
        #expect(state.takePendingPresentation() == nil)
    }

    @Test
    @MainActor
    func passcodeBiometricSuccessWaitsForReactivation()
        async throws
    {
        let fixture = try await makeFixture()
        defer { fixture.removeSecret() }
        let authorization = try await issueAuthorization(
            fixture: fixture
        )
        var state = SendAuthorizationNavigationState()

        state.acceptAfterPasscode(
            context: Self.reviewContext(fixture.draft),
            authorization: authorization,
            sceneIsActive: false,
            sceneIsBackground: false
        )

        #expect(state.takePendingPresentation(sceneIsActive: false) == nil)
        state.resumeAfterInactive()
        guard let presentation = state.takePendingPresentation(),
              case .broadcast = presentation else {
            Issue.record(
                "Passcode-screen biometrics must navigate once authenticated."
            )
            return
        }
        state.resumeAfterInactive()
        #expect(state.takePendingPresentation() == nil)
    }

    @Test(arguments: [false, true])
    @MainActor
    func successfulSendAuthorizationCannotNavigateAfterBackground(invalidatedBeforeCallback: Bool) async throws {
        let fixture = try await makeFixture()
        defer { fixture.removeSecret() }
        let authorization = try await issueAuthorization(fixture: fixture)
        var state = SendAuthorizationNavigationState()
        let pendingID = state.beginAuthorization()
        let requestID = try #require(pendingID)
        if invalidatedBeforeCallback { state.invalidateForBackground() }
        state.receive(
            .authorized(authorization), context: Self.reviewContext(fixture.draft),
            requestID: requestID, sceneIsActive: false, sceneIsBackground: true
        )
        state.resumeAfterInactive()
        #expect(state.activeRequestID == nil)
        #expect(!state.isAuthorizing)
        #expect(state.takePendingPresentation() == nil)
    }

    @Test
    @MainActor
    func backgroundedPasscodeSuccessDoesNotStageBroadcast() async throws {
        let fixture = try await makeFixture()
        defer { fixture.removeSecret() }
        let authorization = try await issueAuthorization(fixture: fixture)
        var state = SendAuthorizationNavigationState()
        state.acceptAfterPasscode(
            context: Self.reviewContext(fixture.draft), authorization: authorization,
            sceneIsActive: false, sceneIsBackground: true
        )
        state.resumeAfterInactive()
        #expect(state.takePendingPresentation() == nil)
    }

    @Test(arguments: [false, true])
    func sendRetainsPasscodeUntilTheSceneCanPresentIt(activeAtCallback: Bool) throws {
        let draft = Self.authorizationDraft(
            sourceAddress: "0x0000000000000000000000000000000000000001"
        )
        var state = SendAuthorizationNavigationState()
        let pendingID = state.beginAuthorization()
        let requestID = try #require(pendingID)
        state.receive(
            .requiresPasscode(initialErrorKey: "security.authentication.biometric.error"),
            context: Self.reviewContext(draft), requestID: requestID,
            sceneIsActive: activeAtCallback
        )
        #expect(state.takePendingPresentation(sceneIsActive: false) == nil)
        state.resumeAfterInactive()
        guard case let .passcode(context, errorKey) = state.takePendingPresentation(sceneIsActive: true) else {
            Issue.record("Passcode fallback must remain pending until the scene is active")
            return
        }
        #expect(context.reviewedDraft == draft)
        #expect(errorKey == "security.authentication.biometric.error")
        #expect(state.takePendingPresentation() == nil)
    }

    @Test
    func sliderResetIsExplicitForCancellationFailureAndBackground() throws {
        let draft = Self.authorizationDraft(
            sourceAddress: "0x0000000000000000000000000000000000000001"
        )
        for reason in ["cancelled", "failed", "background", "passcodeCancelled"] {
            var state = SendAuthorizationNavigationState()
            let original = state.reviewResetID
            let pendingRequest = state.beginAuthorization()
            let request = try #require(pendingRequest)
            #expect(state.reviewResetID == original)
            switch reason {
            case "cancelled":
                state.receive(.cancelled, context: Self.reviewContext(draft), requestID: request,
                              sceneIsActive: false)
            case "failed":
                let staleFailure = state.fail(requestID: UUID())
                #expect(!staleFailure)
                #expect(state.reviewResetID == original, "A stale callback must not reset a newer slide")
                let activeFailure = state.fail(requestID: request)
                #expect(activeFailure)
            case "background":
                state.invalidateForBackground()
            default:
                state.receive(.requiresPasscode(initialErrorKey: nil), context: Self.reviewContext(draft),
                              requestID: request, sceneIsActive: true)
                #expect(state.reviewResetID == original, "Passcode fallback keeps the completed check")
                state.cancelAuthorization()
            }
            #expect(state.reviewResetID != original)
            #expect(!state.isAuthorizing)
        }
    }

    private func makeFixture() async throws
        -> SendTransactionAuthorizationFixture
    {
        let database = try WalletDatabase.temporary()
        let walletDraft = try WalletCoreService.generateEVMWallet()
        let identity = try await database.persistCreatedWallet(
            draft: walletDraft,
            security: .reuseExistingProfile
        )
        let accounts = try await WalletDataStore(
            database: database
        ).accounts(walletID: identity.walletID)
        let account = try #require(
            accounts.first { $0.networkID == "eth" }
        )
        let secretReference = try await database.pool.read { database in
            try #require(
                DBWalletRecord.fetchOne(
                    database,
                    key: identity.walletID
                )?.secretKeyReference
            )
        }
        return SendTransactionAuthorizationFixture(
            database: database,
            walletID: identity.walletID,
            account: account,
            secretReference: secretReference,
            draft: Self.authorizationDraft(
                sourceAddress: account.address
            )
        )
    }

    private func issueAuthorization(
        fixture: SendTransactionAuthorizationFixture
    ) async throws -> SendTransactionAuthorization {
        let route = try await SendAuthorizationRouter(
            database: fixture.database
        ).prepare(for: fixture.draft)
        guard case let .authorized(authorization) = route else {
            Issue.record(
                "An unprotected wallet must issue a Send authorization."
            )
            throw SendTransactionSubmissionError.authorizationExpired
        }
        return authorization
    }

    private func enableBiometrics(
        database: WalletDatabase
    ) async throws -> String {
        try await database.enableAppLock(passcode: "123456")
        try await database.setBiometricEnabled(true)
        return try await database.pool.read { database in
            try #require(
                DBProfileSecurityRecord.fetchOne(
                    database,
                    key: WalletDatabase.defaultProfileID
                )?.passcodeKeychainReference
            )
        }
    }

    @Test
    func postBroadcastRefreshRoutesEverySupportedMainnet() throws {
        for option in AssetNetworkSelectorOption.allSupported {
            let route = try SendPostBroadcastChainRefreshRoute.resolve(
                networkID: option.id
            )
            if let expectedChain = BitcoinFamilyChain(
                rawValue: option.id
            ) {
                guard case let .bitcoinFamily(actualChain) = route else {
                    Issue.record("Bitcoin-family network used wrong route")
                    continue
                }
                #expect(actualChain.networkID == expectedChain.networkID)
            } else if AnkrAPIClient.supportsTokenLookup(
                networkID: option.id
            ) {
                guard case .evm = route else {
                    Issue.record("EVM network used wrong route")
                    continue
                }
            } else {
                switch option.id {
                case SolanaConstants.networkID:
                    guard case .solana = route else {
                        Issue.record("Solana used wrong route")
                        continue
                    }
                case TronConstants.networkID:
                    guard case .tron = route else {
                        Issue.record("Tron used wrong route")
                        continue
                    }
                case TONConstants.networkID:
                    guard case .ton = route else {
                        Issue.record("TON used wrong route")
                        continue
                    }
                case SuiConstants.networkID:
                    guard case .sui = route else {
                        Issue.record("Sui used wrong route")
                        continue
                    }
                case XRPConstants.networkID:
                    guard case .xrp = route else {
                        Issue.record("XRP used wrong route")
                        continue
                    }
                case NEARConstants.networkID:
                    guard case .near = route else {
                        Issue.record("NEAR used wrong route")
                        continue
                    }
                case AptosConstants.networkID:
                    guard case .aptos = route else {
                        Issue.record("Aptos used wrong route")
                        continue
                    }
                case StellarConstants.networkID:
                    guard case .stellar = route else {
                        Issue.record("Stellar used wrong route")
                        continue
                    }
                default:
                    Issue.record("Supported mainnet has no refresh route")
                }
            }
        }
    }

    @Test
    func postBroadcastRefreshRejectsUnknownNetworks() {
        #expect(throws: SendPostBroadcastChainRefreshError.self) {
            _ = try SendPostBroadcastChainRefreshRoute.resolve(
                networkID: "unsupported_testnet"
            )
        }
    }

    @Test
    func postBroadcastRefreshWaitsExactlyTwoSeconds() async {
        let probe = SendPostBroadcastDurationProbe()
        let scheduler = SendPostBroadcastChainRefreshScheduler {
            duration in
            await probe.record(duration)
        }

        #expect(await scheduler.wait())
        #expect(await probe.recorded == [.seconds(2)])
    }

    @Test
    func allBroadcastOutcomesWithEvidenceRefresh() {
        let receipt = Self.postBroadcastReceipt()
        let unknown = SendTransactionSubmissionError
            .broadcastOutcomeUnknown(
                networkID: receipt.networkID,
                code: "transport",
                receipt: receipt
            )
        let executed = SendTransactionSubmissionError
            .broadcastExecutionFailed(
                code: "reverted",
                message: "reverted",
                receipt: receipt
            )
        let rejected = SendTransactionSubmissionError
            .broadcastRejected(
                code: "rejected",
                message: "rejected",
                receipt: receipt
            )

        #expect(
            SendPostBroadcastChainRefreshPolicy.refreshReceipt(
                for: unknown
            ) == receipt
        )
        #expect(
            SendPostBroadcastChainRefreshPolicy.refreshReceipt(
                for: executed
            ) == receipt
        )
        #expect(
            SendPostBroadcastChainRefreshPolicy.refreshReceipt(
                for: rejected
            ) == receipt
        )
    }

    private static func postBroadcastReceipt()
        -> SendTransactionReceipt {
        SendTransactionReceipt(
            transactionHash: String(repeating: "a", count: 64),
            accountID: "account",
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            fromAddress: "sender",
            toAddress: "recipient",
            assetID: "bitcoin:native",
            assetSymbol: "BTC",
            amount: "0.001",
            amountAtomic: "100000",
            networkFee: "0.00001",
            networkFeeAtomic: "1000",
            networkFeeSymbol: "BTC",
            submittedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func authorizationDraft(
        sourceAddress: String
    ) -> SendDraft {
        SendDraft(
            request: .manualEntry(networkID: "eth"),
            asset: SendAssetChoice(
                id: "ethereum:native",
                name: "Ethereum",
                symbol: "ETH",
                networkID: "eth",
                networkName: "Ethereum",
                blockchain: .ethereum,
                contractAddress: nil,
                decimals: 18,
                logoSource: .nativeCoin(blockchain: .ethereum),
                networkLogoSource: .nativeCoin(
                    blockchain: .ethereum
                ),
                balance: 10,
                fiatValue: 20_000,
                balanceAtomic: "10000000000000000000",
                sourceAddress: sourceAddress
            ),
            recipient:
                "0x0000000000000000000000000000000000000001",
            amount: "1",
            note: "Reviewed note"
        )
    }

    private static func bitcoinAuthorizationDraft(
        sourceAddress: String,
        recipient: String
    ) -> SendDraft {
        SendDraft(
            request: .manualEntry(
                networkID: BitcoinFamilyChain.bitcoin.networkID
            ),
            asset: SendAssetChoice(
                id: "bitcoin:native",
                name: "Bitcoin",
                symbol: "BTC",
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                networkName: "Bitcoin",
                blockchain: .bitcoin,
                contractAddress: nil,
                decimals: 8,
                logoSource: .nativeCoin(blockchain: .bitcoin),
                networkLogoSource: .nativeCoin(blockchain: .bitcoin),
                balance: 0.001,
                fiatValue: 100,
                balanceAtomic: "100000",
                sourceAddress: sourceAddress
            ),
            recipient: recipient,
            amount: "0.0001",
            note: nil
        )
    }

    private static func reviewContext(
        _ draft: SendDraft
    ) -> SendAuthorizationReviewContext {
        SendAuthorizationReviewContext(
            sourceRouteDraft: draft,
            reviewedDraft: draft
        )
    }

    private static func dogecoinReviewDraft() -> SendDraft {
        SendDraft(
            request: .manualEntry(networkID: "doge"),
            asset: SendAssetChoice(
                id: "dogecoin:native",
                name: "Dogecoin",
                symbol: "DOGE",
                networkID: "doge",
                networkName: "Dogecoin",
                blockchain: .dogecoin,
                contractAddress: nil,
                decimals: 8,
                logoSource: .nativeCoin(blockchain: .dogecoin),
                networkLogoSource: .nativeCoin(
                    blockchain: .dogecoin
                ),
                balance: 127,
                fiatValue: 12,
                balanceAtomic: "12700000000"
            ),
            recipient: "DD4KSSuBJqcjuTcvUg1CgUKeurPUFeEZkE",
            amount: "10",
            note: nil
        )
    }
}

private actor SendPostBroadcastDurationProbe {
    private(set) var recorded: [Duration] = []

    func record(_ duration: Duration) {
        recorded.append(duration)
    }
}

private struct SendTransactionAuthorizationFixture {
    let database: WalletDatabase
    let walletID: String
    let account: DBWalletAccountRecord
    let secretReference: String
    let draft: SendDraft

    func removeSecret() {
        try? WalletSecretVault.shared.deleteIfPresent(
            reference: secretReference
        )
    }
}
