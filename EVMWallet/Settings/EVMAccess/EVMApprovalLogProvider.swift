import Foundation

struct EVMApprovalLogPage: Sendable {
    let logs: [EVMApprovalEventLog]
    let nextPageToken: String?
}

struct EVMApprovalEventLog: Hashable, Sendable {
    let contractAddress: String
    let topics: [String]
    let data: String
    let transactionHash: String?
    let blockNumber: String?
}

protocol EVMApprovalLogProviding: Sendable {
    func page(
        networkID: String,
        ownerAddress: String,
        pageToken: String?
    ) async throws -> EVMApprovalLogPage
}

private struct AnkrApprovalLogParameters: Encodable, Sendable {
    let blockchain: String
    let decodeLogs = false
    let descOrder = true
    let fromBlock = "earliest"
    let pageSize: Int
    let pageToken: String?
    let toBlock = "latest"
    let topics: [[String]]
}

private struct AnkrApprovalLogResult: Decodable, Sendable {
    let logs: [AnkrApprovalLog]
    let nextPageToken: String?
}

private struct AnkrApprovalLog: Decodable, Sendable {
    let address: String
    let topics: [String]
    let data: String
    let transactionHash: String?
    let blockNumber: LosslessJSONText?
}

private struct LosslessJSONText: Decodable, Sendable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let integer = try? container.decode(Int64.self) {
            value = String(integer)
        } else if let unsigned = try? container.decode(UInt64.self) {
            value = String(unsigned)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected lossless text"
                )
            )
        }
    }
}

actor EVMApprovalLogProvider: EVMApprovalLogProviding {
    static let approvalTopic =
        "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"
    static let approvalForAllTopic =
        "0x17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937696c31"

    private let transport: AnkrRPCTransport

    init(transport: AnkrRPCTransport) {
        self.transport = transport
    }

    init(configuration: AnkrConfiguration, session: URLSession? = nil) {
        transport = AnkrRPCTransport(
            endpoint: configuration.multichainEndpoint,
            session: session
        )
    }

    static func configured(session: URLSession? = nil) throws
        -> EVMApprovalLogProvider {
        EVMApprovalLogProvider(
            configuration: try .runtime(),
            session: session
        )
    }

    func page(
        networkID: String,
        ownerAddress: String,
        pageToken: String?
    ) async throws -> EVMApprovalLogPage {
        guard AnkrAPIClient.usesAdvancedHistory(networkID: networkID),
              let ownerTopic = Self.addressTopic(ownerAddress)
        else {
            throw AnkrAPIError.invalidWalletAddress
        }
        let result: AnkrApprovalLogResult = try await transport.call(
            method: "ankr_getLogs",
            parameters: AnkrApprovalLogParameters(
                blockchain: networkID,
                pageSize: 1_000,
                pageToken: pageToken,
                topics: [
                    [Self.approvalTopic, Self.approvalForAllTopic],
                    [ownerTopic]
                ]
            )
        )
        let logs = try result.logs.map { log in
            let address = log.address.lowercased()
            let topics = log.topics.map { $0.lowercased() }
            let data = log.data.lowercased()
            guard AnkrAPIClient.isValidAddress(address),
                  (2...4).contains(topics.count),
                  topics.allSatisfy(Self.isTopic),
                  Self.isHexData(data),
                  topics[1] == ownerTopic
            else {
                throw AnkrAPIError.invalidResponse
            }
            return EVMApprovalEventLog(
                contractAddress: address,
                topics: topics,
                data: data,
                transactionHash: log.transactionHash?.lowercased(),
                blockNumber: try Self.decimalBlockNumber(
                    log.blockNumber?.value
                )
            )
        }
        return EVMApprovalLogPage(
            logs: logs,
            nextPageToken: Self.pageToken(result.nextPageToken)
        )
    }

    nonisolated static func addressTopic(_ address: String) -> String? {
        let normalized = address.lowercased()
        guard AnkrAPIClient.isValidAddress(normalized) else { return nil }
        return "0x000000000000000000000000"
            + normalized.dropFirst(2)
    }

    private nonisolated static func isTopic(_ value: String) -> Bool {
        value.count == 66
            && value.hasPrefix("0x")
            && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private nonisolated static func isHexData(_ value: String) -> Bool {
        value.hasPrefix("0x")
            && value.dropFirst(2).count.isMultiple(of: 2)
            && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private nonisolated static func pageToken(_ value: String?) -> String? {
        guard let value = value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        return value
    }

    private nonisolated static func decimalBlockNumber(
        _ value: String?
    ) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("0x") {
            return try SendAtomicAmount.decimalFromHexQuantity(value)
        }
        guard value.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw AnkrAPIError.invalidResponse
        }
        let trimmed = value.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }
}
