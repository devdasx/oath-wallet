import Foundation

struct NEARFastAccountHistoryPage: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let transactionHash: String
        let timestamp: String
        let height: Int64
        let index: Int64
        let succeeded: Bool

        enum CodingKeys: String, CodingKey {
            case transactionHash = "transaction_hash"
            case timestamp = "tx_block_timestamp"
            case height = "tx_block_height"
            case index = "tx_index"
            case succeeded = "is_success"
        }
    }

    let items: [Item]
    let resumeToken: String?

    enum CodingKeys: String, CodingKey {
        case items = "account_txs"
        case resumeToken = "resume_token"
    }
}

struct NEARFastTransactionDetails: Decodable, Sendable {
    let transactions: [NEARJSONValue]
}

enum NEARHistoryDetailsBatchLoader {
    static func load<Value: Sendable>(
        hashes: [String],
        batchSize: Int,
        maximumConcurrency: Int,
        loader: @escaping @Sendable ([String]) async throws -> [Value]
    ) async throws -> [Value] {
        guard !hashes.isEmpty else { return [] }
        guard batchSize > 0, maximumConcurrency > 0 else { return [] }

        let batches = stride(from: 0, to: hashes.count, by: batchSize).map {
            Array(hashes[$0..<min($0 + batchSize, hashes.count)])
        }
        return try await withThrowingTaskGroup(
            of: [Value].self,
            returning: [Value].self
        ) { group in
            var nextBatchIndex = 0
            var output: [Value] = []

            func submitNextBatch() {
                guard nextBatchIndex < batches.count else { return }
                let batch = batches[nextBatchIndex]
                nextBatchIndex += 1
                group.addTask {
                    try Task.checkCancellation()
                    return try await loader(batch)
                }
            }

            for _ in 0..<min(maximumConcurrency, batches.count) {
                submitNextBatch()
            }
            while let values = try await group.next() {
                output.append(contentsOf: values)
                submitNextBatch()
            }
            return output
        }
    }
}
