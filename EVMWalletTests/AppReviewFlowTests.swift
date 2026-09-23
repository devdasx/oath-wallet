import Foundation
import Testing
import UIKit
@testable import Aperture

@Suite(.serialized)
struct AppReviewFlowTests {
    @Test
    func explicitReviewDestinationOpensAppStoreComposer() throws {
        let url = AppStoreReviewDestination.writeReviewURL
        let components = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )

        #expect(components.scheme == "https")
        #expect(components.host == "apps.apple.com")
        #expect(
            components.path
                == "/app/id\(AppStoreReviewDestination.appStoreIdentifier)"
        )
        #expect(
            components.queryItems
                == [URLQueryItem(name: "action", value: "write-review")]
        )
    }

    @Test
    func reviewAnimationUsesCompactNativeSymbols() {
        #expect(AppReviewAnimationHeroMetrics.sideLength == 104)
        #expect(AppReviewAnimationHeroMetrics.symbolPointSize == 82)
        #expect(
            AppReviewAnimationHeroMetrics.sentimentSymbolName
                == "heart.square"
        )
        #expect(
            AppReviewAnimationHeroMetrics.thanksSymbolName
                == "checkmark.seal"
        )
        #expect(
            AppReviewAnimationHeroMetrics.effectOptions
                == .nonRepeating
        )
        #expect(
            UIImage(
                systemName:
                    AppReviewAnimationHeroMetrics.sentimentSymbolName
            ) != nil
        )
        #expect(
            UIImage(
                systemName:
                    AppReviewAnimationHeroMetrics.thanksSymbolName
            ) != nil
        )
    }

    @Test
    @MainActor
    func debugPromptCanBeTestedRepeatedlyWithoutConsumingEligibility()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let invoker = AppReviewFunctionInvokerProbe()
        let coordinator = AppReviewPromptCoordinator(
            database: database,
            feedbackClient: AppReviewFeedbackClient(invoker: invoker)
        )

        coordinator.presentForTesting()
        #expect(coordinator.isSheetPresented)
        coordinator.chooseNotEnjoying()
        try await coordinator.submitFeedback(
            reason: .other,
            feedback: "Test feedback",
            languageIdentifier: "en-US"
        )
        let request = try #require(await invoker.lastRequest())
        #expect(request.path == "feedback-email")
        coordinator.finishFeedback()
        #expect(!coordinator.sheetDidDismiss())

        coordinator.presentForTesting()
        coordinator.chooseEnjoying()
        #expect(coordinator.sheetDidDismiss())

        let snapshot = try await database.appReviewPromptSnapshot()
        #expect(!snapshot.wasPresented)
        #expect(snapshot.response == nil)
        #expect(snapshot.feedbackSubmittedAt == nil)
    }

    @Test
    func usagePolicyAccumulatesOnlyPositiveMonotonicTime() {
        #expect(
            AppReviewUsagePolicy.elapsedMilliseconds(
                from: 10,
                to: 10.125
            ) == 125
        )
        #expect(
            AppReviewUsagePolicy.elapsedMilliseconds(
                from: 10,
                to: 10
            ) == 0
        )
        #expect(
            AppReviewUsagePolicy.elapsedMilliseconds(
                from: 10,
                to: 9
            ) == 0
        )
    }

    @Test
    func presentationIsClaimedExactlyOnceAfterFiveMinutes()
        async throws
    {
        let database = try WalletDatabase.temporary()

        var snapshot = try await database.appReviewPromptSnapshot()
        #expect(snapshot.accumulatedActiveMilliseconds == 0)
        #expect(!snapshot.wasPresented)

        snapshot = try await database.addAppReviewActiveUsage(
            milliseconds:
                AppReviewUsagePolicy.presentationThresholdMilliseconds - 1
        )
        #expect(!snapshot.wasPresented)
        #expect(
            try await database.claimAppReviewPromptPresentation(
                thresholdMilliseconds:
                    AppReviewUsagePolicy
                        .presentationThresholdMilliseconds
            ) == false
        )

        snapshot = try await database.addAppReviewActiveUsage(
            milliseconds: 1
        )
        #expect(
            snapshot.accumulatedActiveMilliseconds
                == AppReviewUsagePolicy.presentationThresholdMilliseconds
        )
        #expect(
            try await database.claimAppReviewPromptPresentation(
                thresholdMilliseconds:
                    AppReviewUsagePolicy
                        .presentationThresholdMilliseconds
            )
        )
        #expect(
            try await database.claimAppReviewPromptPresentation(
                thresholdMilliseconds:
                    AppReviewUsagePolicy
                        .presentationThresholdMilliseconds
            ) == false
        )
    }

    @Test
    func responseCannotBeReplacedAndSurvivesAppDataReset()
        async throws
    {
        let database = try WalletDatabase.temporary()
        _ = try await database.addAppReviewActiveUsage(
            milliseconds:
                AppReviewUsagePolicy.presentationThresholdMilliseconds
        )
        #expect(
            try await database.claimAppReviewPromptPresentation(
                thresholdMilliseconds:
                    AppReviewUsagePolicy
                        .presentationThresholdMilliseconds
            )
        )

        try await database.recordAppReviewPromptResponse(.notEnjoying)
        try await database.recordAppReviewPromptResponse(.enjoying)
        try await database.markAppReviewFeedbackSubmitted()
        try await database.eraseAllData()

        let restored = try await database.appReviewPromptSnapshot()
        #expect(restored.wasPresented)
        #expect(restored.response == .notEnjoying)
        #expect(restored.feedbackSubmittedAt != nil)
    }

    @Test
    func feedbackClientSendsNormalizedPrivatePayload() async throws {
        let invoker = AppReviewFunctionInvokerProbe()
        let client = AppReviewFeedbackClient(
            invoker: invoker,
            appVersion: { "2.4" },
            appBuild: { "37" }
        )

        try await client.submit(
            reason: .missingFeature,
            feedback: "  Please add this.  ",
            languageIdentifier: "he_IL"
        )

        let request = try #require(await invoker.lastRequest())
        #expect(request.path == "feedback-email")
        let object = try #require(
            try JSONSerialization.jsonObject(with: request.payload)
                as? [String: String]
        )
        #expect(object["reason"] == "missing_feature")
        #expect(object["feedback"] == "Please add this.")
        #expect(object["app_version"] == "2.4")
        #expect(object["app_build"] == "37")
        #expect(object["language_identifier"] == "he-IL")
        #expect(
            Set(object.keys) == Set(
                [
                    "reason",
                    "feedback",
                    "app_version",
                    "app_build",
                    "language_identifier",
                ]
            )
        )
    }

    @Test
    func feedbackClientNormalizesEverySupportedAppLocale() async throws {
        for languageIdentifier in WalletAppLanguage.supportedIdentifiers {
            let invoker = AppReviewFunctionInvokerProbe()
            let client = AppReviewFeedbackClient(invoker: invoker)
            let appLocaleIdentifier = WalletAppLanguage.locale(
                for: languageIdentifier
            ).identifier

            do {
                try await client.submit(
                    reason: .transactionOrNetwork,
                    feedback: "",
                    languageIdentifier: appLocaleIdentifier
                )
            } catch {
                Issue.record(
                    "Failed to normalize \(languageIdentifier) from \(appLocaleIdentifier): \(error)"
                )
                continue
            }

            let request = try #require(await invoker.lastRequest())
            let object = try #require(
                try JSONSerialization.jsonObject(with: request.payload)
                    as? [String: String]
            )
            #expect(
                object["language_identifier"] == languageIdentifier
            )
        }
    }

    @Test
    func feedbackClientRejectsOversizedTextBeforeNetworking()
        async
    {
        let invoker = AppReviewFunctionInvokerProbe()
        let client = AppReviewFeedbackClient(invoker: invoker)

        do {
            try await client.submit(
                reason: .other,
                feedback: String(
                    repeating: "x",
                    count:
                        AppReviewFeedbackClient.maximumFeedbackLength + 1
                ),
                languageIdentifier: "en-US"
            )
            Issue.record("Oversized feedback unexpectedly succeeded.")
        } catch let error as AppReviewFeedbackSubmissionError {
            #expect(error == .invalidFeedback)
        } catch {
            Issue.record("Unexpected feedback error: \(error)")
        }

        #expect(await invoker.lastRequest() == nil)
    }
}

private actor AppReviewFunctionInvokerProbe:
    AppReviewFunctionInvoking {
    struct Request: Sendable {
        let path: String
        let payload: Data
    }

    private var request: Request?

    func invoke(functionPath: String, payload: Data) async throws {
        request = Request(path: functionPath, payload: payload)
    }

    func lastRequest() -> Request? {
        request
    }
}
