import Foundation

/// Shared exact-identity reads. Live receipts and restored database activity
/// share one in-flight lookup; a slow network cannot occupy all four slots.
actor SendStatusRequestPool {
    typealias Reader = @Sendable (SendTransactionReceipt) async throws -> SendTransactionNetworkStatus
    private typealias Completion = CheckedContinuation<SendTransactionNetworkStatus, any Error>
    private struct Job {
        let network: String
        let read: @Sendable () async throws -> SendTransactionNetworkStatus
        var subscribers: [UUID: Completion]
        var isRunning = false
    }
    static let shared = SendStatusRequestPool()
    private let reader: Reader
    private let limit: Int
    private var jobs: [String: Job] = [:]
    private var waiting: [String] = []
    private var activeNetworks = Set<String>()

    init(limit: Int = 4, reader: Reader? = nil) {
        self.limit = max(1, limit)
        let service = SendTransactionStatusService()
        self.reader = reader ?? { try await service.status(for: $0) }
    }

    func status(for receipt: SendTransactionReceipt) async throws -> SendTransactionNetworkStatus {
        let reader = reader
        let senderScope = receipt.networkID == NEARConstants.networkID ? ":" + receipt.fromAddress : ""
        return try await read(key: receipt.networkID + ":" + WalletDatabase.normalizedSendHash(
            receipt.transactionHash, networkID: receipt.networkID) + senderScope, network: receipt.networkID) {
                try await reader(receipt)
            }
    }

    func read(key: String, network: String,
              operation: @escaping @Sendable () async throws -> SendTransactionNetworkStatus) async throws -> SendTransactionNetworkStatus {
        let subscriber = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if jobs[key] != nil { jobs[key]?.subscribers[subscriber] = continuation }
                else {
                    jobs[key] = Job(network: network, read: operation, subscribers: [subscriber: continuation])
                    waiting.append(key)
                }
                drain()
            }
        } onCancel: {
            Task { await self.cancel(key: key, subscriber: subscriber) }
        }
    }

    private func cancel(key: String, subscriber: UUID) {
        jobs[key]?.subscribers.removeValue(forKey: subscriber)?.resume(throwing: CancellationError())
        guard let job = jobs[key], job.subscribers.isEmpty, !job.isRunning else { return }
        jobs[key] = nil
        waiting.removeAll { $0 == key }
    }

    private func drain() {
        while activeNetworks.count < limit,
              let index = waiting.firstIndex(where: { key in
                  jobs[key].map { !activeNetworks.contains($0.network) } ?? false
              }) {
            let key = waiting.remove(at: index)
            guard var job = jobs[key] else { continue }
            job.isRunning = true
            jobs[key] = job
            activeNetworks.insert(job.network)
            let read = job.read
            // One cancelled observer does not cancel another observer's read.
            // With no subscribers, the bounded in-flight read finishes; queued
            // work is removed immediately on cancellation.
            Task {
                let result: Result<SendTransactionNetworkStatus, any Error>
                do { result = .success(try await read()) }
                catch { result = .failure(error) }
                complete(key: key, result: result)
            }
        }
    }

    private func complete(key: String, result: Result<SendTransactionNetworkStatus, any Error>) {
        guard let job = jobs.removeValue(forKey: key) else { return }
        activeNetworks.remove(job.network)
        for subscriber in job.subscribers.values { subscriber.resume(with: result) }
        drain()
    }
}
