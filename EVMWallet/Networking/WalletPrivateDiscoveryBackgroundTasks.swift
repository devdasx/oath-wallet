import BackgroundTasks
import Foundation

@MainActor
final class WalletPrivateDiscoveryBackgroundTasks {
    typealias Registration = (
        String, DispatchQueue?, @escaping (BGTask) -> Void
    ) -> Bool

    static let shared = WalletPrivateDiscoveryBackgroundTasks()
    static let taskIdentifier =
        "com.aperture.wallet.private-discovery"

    private struct PendingTask {
        let id: UUID
        let task: BGProcessingTask
    }

    private var isRegistered = false
    private var database: WalletDatabase?
    private var pendingTask: PendingTask?
    private var workTask: Task<Void, Never>?
    private let registerTask: Registration

    init(registerTask: @escaping Registration = { identifier, queue, handler in
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: queue,
            launchHandler: handler
        )
    }) {
        self.registerTask = registerTask
    }

    func register() {
        guard !isRegistered else { return }
        // This legacy callback inherits MainActor isolation. A nil queue lets
        // iOS invoke it off-main and trap before the callback body can run.
        isRegistered = registerTask(Self.taskIdentifier, .main) { [weak self] task in
            guard let self, let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.receive(processingTask)
        }
    }

    func install(database: WalletDatabase) {
        self.database = database
        schedule()
        startPendingTaskIfPossible()
    }

    func schedule() {
        guard isRegistered else { return }
        let request = BGProcessingTaskRequest(
            identifier: Self.taskIdentifier
        )
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    private func receive(_ task: BGProcessingTask) {
        schedule()

        if let pendingTask {
            pendingTask.task.setTaskCompleted(success: false)
            workTask?.cancel()
        }

        let operationID = UUID()
        pendingTask = PendingTask(id: operationID, task: task)
        task.expirationHandler = Self.makeExpirationHandler { [weak self] in
            self?.expire(operationID: operationID)
        }
        startPendingTaskIfPossible()
    }

    // BackgroundTasks may enter this legacy callback from a non-main queue.
    // Keep its entry nonisolated; only the state-owning action hops to MainActor.
    nonisolated static func makeExpirationHandler(
        onExpire: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable () -> Void {
        { Task { @MainActor in onExpire() } }
    }

    private func startPendingTaskIfPossible() {
        guard database != nil,
              let pendingTask,
              workTask == nil else { return }
        let operationID = pendingTask.id
        workTask = Task { [weak self] in
            let success = await WalletPrivateDiscoverySyncCoordinator
                .shared.synchronizeAllWalletsForBackgroundProcessing()
            guard !Task.isCancelled else { return }
            self?.finish(
                operationID: operationID,
                success: success
            )
        }
    }

    private func expire(operationID: UUID) {
        guard pendingTask?.id == operationID else { return }
        workTask?.cancel()
        workTask = nil
        pendingTask?.task.setTaskCompleted(success: false)
        pendingTask = nil
    }

    private func finish(operationID: UUID, success: Bool) {
        guard pendingTask?.id == operationID else { return }
        workTask = nil
        pendingTask?.task.setTaskCompleted(success: success)
        pendingTask = nil
    }
}
