import Foundation
import GRDB
import OathBitcoin

public enum ContactStoreError: Error, Equatable, Sendable {
    case invalidName, invalidAddress, invalidLabel, emptyAddresses, tooManyAddresses
    case duplicateAddress, unknownNetwork, conflict, missingContact
}

public struct ContactRecord: Codable, Equatable, Sendable, FetchableRecord {
    public let id: String
    public let name: String
    public let createdAt: Double
    public let updatedAt: Double
    public let revision: Int64
}

public struct ContactSummary: Codable, Equatable, Sendable, FetchableRecord, Identifiable {
    public let id: String
    public let name: String
    public let addressCount: Int
}

public struct ContactAddressInput: Equatable, Sendable, Identifiable {
    public var id: String
    public var networkID: String
    public var address: String
    public var label: String

    public init(id: String = UUID().uuidString, networkID: String, address: String, label: String = "") {
        self.id = id; self.networkID = networkID; self.address = address; self.label = label
    }
}

public struct ContactAddressRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "contactAddresses"
    public let id: String
    public let contactID: String
    public let networkID: String
    public let address: String
    public let addressKey: String
    public let label: String
    public let position: Int

    public var input: ContactAddressInput {
        .init(id: id, networkID: networkID, address: address, label: label)
    }
}

public struct ContactSnapshot: Equatable, Sendable {
    public let contact: ContactRecord
    public let addresses: [ContactAddressRecord]
}

extension OathDatabase {
    public func contacts(matching query: String = "") async throws -> [ContactSummary] {
        try await pool.read { try Self.fetchContacts($0, query: query) }
    }

    public func observeContacts(matching query: String = "") -> AsyncThrowingStream<[ContactSummary], Error> {
        stream { try Self.fetchContacts($0, query: query) }
    }

    public func contact(_ id: String) async throws -> ContactSnapshot? {
        try await pool.read { try Self.fetchContact($0, id: id) }
    }

    public func observeContact(_ id: String) -> AsyncThrowingStream<ContactSnapshot?, Error> {
        stream { try Self.fetchContact($0, id: id) }
    }

    /// Match a destination only on its explicit network. UTXO aliases can encode
    /// the same locking script (for example CashAddr and a legacy BCH address).
    public func observeContactAddress(networkID: String, address: String) -> AsyncThrowingStream<Bool, Error> {
        stream { try Self.containsContactAddress($0, networkID: networkID, address: address) }
    }

    static func containsContactAddress(_ db: Database, networkID: String, address: String) throws -> Bool {
        guard let network = try NetworkRecord.fetchOne(db, key: networkID) else { throw ContactStoreError.unknownNetwork }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = try String.fetchAll(db, sql: "SELECT address FROM contactAddresses WHERE networkID=?", arguments: [networkID])
        if network.family == "evm" { return saved.contains { $0.lowercased() == address.lowercased() } }
        if saved.contains(address) { return true }
        // Alternative address decoding is expected validation, not an app failure.
        guard let chain = UTXONetwork(rawValue: networkID),
              let script = try? BitcoinSendPlan.recipientScript(address, chain: chain) else { return false }
        return saved.contains { (try? BitcoinSendPlan.recipientScript($0, chain: chain)) == script }
    }

    /// A name-only contact is valid. The contact, any addresses, and their search index commit together. An
    /// expected revision prevents an older editor from overwriting a newer edit
    /// or resurrecting a deleted contact. Contacts belong to the app, not a wallet.
    @discardableResult
    public func saveContact(id: String, name: String, addresses: [ContactAddressInput],
                            expectedRevision: Int64? = nil, rejectExistingAddresses: Bool = false) async throws -> ContactSnapshot {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.count <= 100,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ContactStoreError.invalidName
        }
        guard addresses.count <= 50 else { throw ContactStoreError.tooManyAddresses }
        guard UUID(uuidString: id) != nil, Set(addresses.map(\.id)).count == addresses.count,
              addresses.allSatisfy({ UUID(uuidString: $0.id) != nil }) else { throw ContactStoreError.conflict }
        try Task.checkCancellation()
        return try await pool.write { db in
            let old = try ContactRecord.fetchOne(db, sql: "SELECT * FROM contacts WHERE id=?", arguments: [id])
            if expectedRevision != nil, old == nil { throw ContactStoreError.missingContact }
            guard old?.revision == expectedRevision else { throw ContactStoreError.conflict }
            var seen = Set<[String]>()
            var searchParts: [String] = []
            let rows = try addresses.enumerated().map { position, entry -> ContactAddressRecord in
                guard let network = try NetworkRecord.fetchOne(db, key: entry.networkID) else {
                    throw ContactStoreError.unknownNetwork
                }
                let address = entry.address.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
                // Chain checksum/encoding validation belongs to the wallet
                // engine. Storage independently rejects empty/non-address data.
                guard !address.isEmpty, address.utf8.count <= 256,
                      address.utf8.allSatisfy({ (33...126).contains($0) }) else { throw ContactStoreError.invalidAddress }
                guard label.count <= 60,
                      !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw ContactStoreError.invalidLabel
                }
                let key = network.family == "evm" ? address.lowercased() : address
                guard seen.insert([network.id, key]).inserted else { throw ContactStoreError.duplicateAddress }
                // Receipt quick-add checks again in the writer transaction, so
                // another editor cannot create a duplicate after its lookup.
                if rejectExistingAddresses, try Self.containsContactAddress(db, networkID: network.id, address: address) {
                    throw ContactStoreError.duplicateAddress
                }
                if let owner = try String.fetchOne(db, sql: "SELECT contactID FROM contactAddresses WHERE id=?", arguments: [entry.id]), owner != id {
                    throw ContactStoreError.conflict
                }
                searchParts.append("\(label) \(network.id) \(network.name) \(network.symbol) \(address)")
                return ContactAddressRecord(id: entry.id, contactID: id, networkID: network.id,
                    address: address, addressKey: key, label: label, position: position)
            }
            let now = Date.now.timeIntervalSince1970
            // Derived search text is maintained only here, in the same writer
            // transaction. Displayed contact values always use the normalized tables.
            let searchText = searchParts.joined(separator: " ")
            if let old {
                try db.execute(sql: "UPDATE contacts SET name=?,searchText=?,updatedAt=?,revision=? WHERE id=?",
                    arguments: [name, searchText, now, old.revision + 1, id])
            } else {
                try db.execute(sql: "INSERT INTO contacts(id,name,searchText,createdAt,updatedAt,revision) VALUES(?,?,?,?,?,1)",
                    arguments: [id, name, searchText, now, now])
            }
            try db.execute(sql: "DELETE FROM contactAddresses WHERE contactID=?", arguments: [id])
            for row in rows { try row.insert(db) }
            guard let saved = try Self.fetchContact(db, id: id) else { throw ContactStoreError.missingContact }
            return saved
        }
    }

    public func deleteContact(_ id: String, expectedRevision: Int64) async throws {
        try Task.checkCancellation()
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM contacts WHERE id=? AND revision=?", arguments: [id, expectedRevision])
            guard db.changesCount == 1 else { throw ContactStoreError.conflict }
        }
    }

    private static func fetchContact(_ db: Database, id: String) throws -> ContactSnapshot? {
        guard let contact = try ContactRecord.fetchOne(db, sql: "SELECT * FROM contacts WHERE id=?", arguments: [id]) else { return nil }
        return ContactSnapshot(contact: contact, addresses: try ContactAddressRecord.fetchAll(db,
            sql: "SELECT * FROM contactAddresses WHERE contactID=? ORDER BY position,id", arguments: [id]))
    }

    private static func fetchContacts(_ db: Database, query: String) throws -> [ContactSummary] {
        // Quote each token so user text cannot become an FTS operator. Prefix
        // indexes find partial names and pasted address prefixes without LIKE scans.
        let terms = query.prefix(256).split(whereSeparator: \.isWhitespace).prefix(12)
        let match = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " AND ")
        var sql = """
            SELECT c.id,c.name,(SELECT count(*) FROM contactAddresses a WHERE a.contactID=c.id) AS addressCount
            FROM contacts c
            """
        var arguments = StatementArguments()
        if !match.isEmpty {
            sql += " WHERE c.rowid IN (SELECT rowid FROM contactsSearch WHERE contactsSearch MATCH ?)"
            arguments += [match]
        }
        sql += " ORDER BY c.name COLLATE NOCASE,c.id"
        return try ContactSummary.fetchAll(db, sql: sql, arguments: arguments)
    }
}
