import Foundation
import GRDB

/// One saved address on the explicitly chosen network. Never merge identical
/// EVM addresses across networks or guess a network from the address encoding.
public struct SendRecipient: Decodable, FetchableRecord, Sendable, Equatable, Identifiable {
    public let id: String
    public let contactID: String
    public let name: String
    public let label: String
    public let address: String
    public let networkID: String
}

extension OathDatabase {
    public func sendRecipients(networkID: String) async throws -> [SendRecipient] {
        try await pool.read { try Self.fetchSendRecipients($0, networkID: networkID) }
    }

    public func observeSendRecipients(networkID: String) -> AsyncThrowingStream<[SendRecipient], Error> {
        stream { try Self.fetchSendRecipients($0, networkID: networkID) }
    }

    private static func fetchSendRecipients(_ db: Database, networkID: String) throws -> [SendRecipient] {
        try SendRecipient.fetchAll(db, sql: """
            SELECT a.id, a.contactID, c.name, a.label, a.address, a.networkID
            FROM contactAddresses a JOIN contacts c ON c.id = a.contactID
            WHERE a.networkID = ?
            ORDER BY c.name COLLATE NOCASE, c.id, a.position, a.id
            """, arguments: [networkID])
    }
}
