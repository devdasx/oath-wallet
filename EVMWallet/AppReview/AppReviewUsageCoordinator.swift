import Foundation
import Observation

enum AppReviewUsagePolicy {
    static let presentationThresholdMilliseconds: Int64 = 300_000
    static let maximumCheckpointInterval: Duration = .seconds(5)

    static func elapsedMilliseconds(
        from start: TimeInterval,
        to end: TimeInterval
    ) -> Int64 {
        guard start.isFinite, end.isFinite, end > start else {
            return 0
        }
        let milliseconds = (end - start) * 1_000
        guard milliseconds < Double(Int64.max) else {
            return Int64.max
        }
        return max(0, Int64(milliseconds.rounded(.down)))
    }
}

private actor AppReviewUsageEngine {
    typealias UptimeProvider = @Sendable () -> TimeInterval

    private let database: WalletDatabase
    private let uptime: UptimeProvider
    private var activeSegmentStartedAt: TimeInterval?
    private var snapshot: AppReviewPromptSnapshot?

    init(
        database: WalletDatabase,
        uptime: @escaping UptimeProvider = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.database = database
        self.uptime = uptime
    }

    func setActive(_ isActive: Bool) async
        -> AppReviewPromptSnapshot? {
        guard var current = await loadSnapshotIfNeeded() else {
            return nil
        }
        guard !current.wasPresented else {
            activeSegmentStartedAt = nil
            return current
        }

        if isActive {
            if activeSegmentStartedAt == nil {
                activeSegmentStartedAt = uptime()
            }
            return current
        }

        current = await persistActiveSegment(fallback: current)
        activeSegmentStartedAt = nil
        return current
    }

    func checkpoint() async -> AppReviewPromptSnapshot? {
        guard let current = await loadSnapshotIfNeeded() else {
            return nil
        }
        return await persistActiveSegment(fallback: current)
    }

    func claimPresentationIfEligible() async -> Bool {
        guard let current = await checkpoint(),
              !current.wasPresented,
              current.accumulatedActiveMilliseconds
                >= AppReviewUsagePolicy
                    .presentationThresholdMilliseconds else {
            return false
        }
        do {
            let claimed = try await database
                .claimAppReviewPromptPresentation(
                    thresholdMilliseconds:
                        AppReviewUsagePolicy
                            .presentationThresholdMilliseconds
                )
            if claimed {
                snapshot = try await database.appReviewPromptSnapshot()
                activeSegmentStartedAt = nil
            }
            return claimed
        } catch {
            return false
        }
    }

    func recordResponse(_ response: AppReviewPromptResponse) async {
        do {
            try await database.recordAppReviewPromptResponse(response)
            snapshot = try await database.appReviewPromptSnapshot()
        } catch {
            return
        }
    }

    func markFeedbackSubmitted() async {
        do {
            try await database.markAppReviewFeedbackSubmitted()
            snapshot = try await database.appReviewPromptSnapshot()
        } catch {
            return
        }
    }

    private func loadSnapshotIfNeeded() async
        -> AppReviewPromptSnapshot? {
        if let snapshot { return snapshot }
        do {
            let loaded = try await database.appReviewPromptSnapshot()
            snapshot = loaded
            return loaded
        } catch {
            return nil
        }
    }

    private func persistActiveSegment(
        fallback: AppReviewPromptSnapshot
    ) async -> AppReviewPromptSnapshot {
        guard let startedAt = activeSegmentStartedAt else {
            return fallback
        }
        let checkpoint = uptime()
        let elapsed = AppReviewUsagePolicy.elapsedMilliseconds(
            from: startedAt,
            to: checkpoint
        )
        guard elapsed > 0 else { return fallback }

        do {
            let updated = try await database.addAppReviewActiveUsage(
                milliseconds: elapsed
            )
            snapshot = updated
            activeSegmentStartedAt = checkpoint
            return updated
        } catch {
            return fallback
        }
    }
}

@MainActor
@Observable
final class AppReviewPromptCoordinator {
    var isSheetPresented = false

    private let usageEngine: AppReviewUsageEngine
    private let feedbackClient: AppReviewFeedbackClient
    private var lifecycleTask: Task<Void, Never>?
    private var hasStarted = false
    private var isUsageActive = false
    private var canPresentSheet = false
    private var selectedResponse: AppReviewPromptResponse?
    private var requestsNativeReviewAfterDismissal = false
    private var isTestingPresentation = false

    init(
        database: WalletDatabase,
        feedbackClient: AppReviewFeedbackClient = .live
    ) {
        usageEngine = AppReviewUsageEngine(database: database)
        self.feedbackClient = feedbackClient
    }

    func start(
        isUsageActive: Bool,
        canPresentSheet: Bool
    ) {
        guard !hasStarted else {
            update(
                isUsageActive: isUsageActive,
                canPresentSheet: canPresentSheet
            )
            return
        }
        hasStarted = true
        update(
            isUsageActive: isUsageActive,
            canPresentSheet: canPresentSheet
        )
    }

    func update(
        isUsageActive: Bool,
        canPresentSheet: Bool
    ) {
        self.isUsageActive = isUsageActive
        self.canPresentSheet = canPresentSheet
        restartLifecycleTask()
    }

    func chooseEnjoying() {
        guard selectedResponse == nil else { return }
        selectedResponse = .enjoying
        requestsNativeReviewAfterDismissal = true
        if !isTestingPresentation {
            Task { await usageEngine.recordResponse(.enjoying) }
        }
        isSheetPresented = false
    }

    func chooseNotEnjoying() {
        guard selectedResponse == nil else { return }
        selectedResponse = .notEnjoying
        if !isTestingPresentation {
            Task { await usageEngine.recordResponse(.notEnjoying) }
        }
    }

    func submitFeedback(
        reason: AppReviewFeedbackReason,
        feedback: String,
        languageIdentifier: String
    ) async throws {
        try await feedbackClient.submit(
            reason: reason,
            feedback: feedback,
            languageIdentifier: languageIdentifier
        )
        guard !isTestingPresentation else { return }
        await usageEngine.markFeedbackSubmitted()
    }

    func finishFeedback() {
        isSheetPresented = false
    }

    func sheetDidDismiss() -> Bool {
        if isTestingPresentation {
            let shouldRequestReview = requestsNativeReviewAfterDismissal
            isTestingPresentation = false
            selectedResponse = nil
            requestsNativeReviewAfterDismissal = false
            return shouldRequestReview
        }
        if selectedResponse == nil {
            selectedResponse = .dismissed
            Task { await usageEngine.recordResponse(.dismissed) }
        }
        let shouldRequestReview = requestsNativeReviewAfterDismissal
        requestsNativeReviewAfterDismissal = false
        return shouldRequestReview
    }

    func presentForTesting() {
#if DEBUG
        guard !isSheetPresented else { return }
        isTestingPresentation = true
        selectedResponse = nil
        requestsNativeReviewAfterDismissal = false
        isSheetPresented = true
#endif
    }

    private func restartLifecycleTask() {
        lifecycleTask?.cancel()
        let usageActive = isUsageActive
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            _ = await usageEngine.setActive(usageActive)
            await evaluatePresentationEligibility()

            while !Task.isCancelled, usageActive {
                do {
                    try await Task.sleep(
                        for: AppReviewUsagePolicy
                            .maximumCheckpointInterval
                    )
                } catch {
                    return
                }
                _ = await usageEngine.checkpoint()
                await evaluatePresentationEligibility()
            }
        }
    }

    private func evaluatePresentationEligibility() async {
        guard canPresentSheet, !isSheetPresented else { return }
        guard await usageEngine.claimPresentationIfEligible() else {
            return
        }
        selectedResponse = nil
        isSheetPresented = true
    }
}
