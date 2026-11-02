import Foundation
import GRDB

/// Solana's two account conventions use hardened Ed25519 derivation throughout.
public enum SolanaDerivation: String, CaseIterable, Codable, Sendable {
    case phantom, trustWallet

    public var title: String { self == .phantom ? "Phantom" : "Trust Wallet" }

    public func path(accountIndex: Int) throws -> String {
        guard (0..<2_147_483_648).contains(accountIndex) else { throw StoreError.invalidValue("Solana account index") }
        let account = "m/44'/501'/\(accountIndex)'"
        return self == .phantom ? account + "/0'" : account
    }

    public static func accountIndex(in path: String) -> Int? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard (4...5).contains(parts.count), parts[0] == "m", parts[1] == "44'", parts[2] == "501'",
              parts[3].last == "'", let index = Int(parts[3].dropLast()), (0..<2_147_483_648).contains(index),
              parts[3] == "\(index)'", parts.count == 4 || parts[4] == "0'" else { return nil }
        return index
    }

    public static func matching(path: String) -> Self? {
        guard accountIndex(in: path) != nil else { return nil }
        return path.split(separator: "/").count == 5 ? .phantom : .trustWallet
    }
}

public struct SolanaReceiveAddress: Codable, Equatable, Sendable, Identifiable {
    public let path: String
    public let address: String
    public var id: String { path }
    public var derivation: SolanaDerivation? { .matching(path: path) }
    public init(path: String, address: String) { self.path = path; self.address = address }
}

public struct SolanaReceiveState: Equatable, Sendable {
    public let addresses: [SolanaReceiveAddress]
    public let selected: SolanaReceiveAddress
}

extension OathDatabase {
    /// Only public addresses are persisted. Keep the original account immutable
    /// so old receive requests and future history still identify the same wallet.
    public func prepareSolanaReceive(accountID: String, addresses: [SolanaReceiveAddress], preferredPath: String) async throws -> SolanaReceiveState {
        guard (1...3).contains(addresses.count), Set(addresses.map(\.path)).count == addresses.count,
              Set(addresses.map(\.address)).count == addresses.count, addresses.contains(where: { $0.path == preferredPath }),
              addresses.allSatisfy({ (32...44).contains($0.address.utf8.count) && $0.path.utf8.count <= 128 &&
                  $0.address.utf8.allSatisfy { "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8.contains($0) } }) else {
            throw StoreError.invalidValue("Solana receive addresses")
        }
        return try await pool.write { db in
            guard let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "solana",
                  addresses.contains(.init(path: account.derivationPath, address: account.address)) else { throw StoreError.conflictingIdentity }
            if account.derivationPath == "solana-multisig-v1" {
                guard addresses.count == 1, try WalletRecord.fetchOne(db,key:account.walletID)?.kind == "solanaMultisig" else { throw StoreError.conflictingIdentity }
            } else if account.derivationPath == "imported" {
                guard addresses.count == 1 else { throw StoreError.conflictingIdentity }
            } else {
                let index = SolanaDerivation.accountIndex(in: account.derivationPath) ?? account.accountIndex
                let paths = try SolanaDerivation.allCases.map { try $0.path(accountIndex: index) }
                guard Set(addresses.map(\.path)) == Set(paths + [account.derivationPath]) else { throw StoreError.conflictingIdentity }
            }
            if let existing = try Self.solanaReceiveState(accountID: accountID, db: db) {
                guard Set(existing.addresses.map(\.path)) == Set(addresses.map(\.path)),
                      existing.addresses.allSatisfy(addresses.contains) else { throw StoreError.conflictingIdentity }
                return existing // Reopening or rederiving never resets the user's choice.
            }
            for address in addresses {
                try db.execute(sql: "INSERT INTO solanaReceiveAddresses(accountID,path,address,isSelected) VALUES(?,?,?,?)",
                    arguments: [accountID, address.path, address.address, address.path == preferredPath])
            }
            return try Self.solanaReceiveState(accountID: accountID, db: db)!
        }
    }

    public func solanaReceiveState(accountID: String) async throws -> SolanaReceiveState? {
        try await pool.read { try Self.solanaReceiveState(accountID: accountID, db: $0) }
    }

    /// Both the selection and returned address come from one transaction.
    public func selectSolanaReceivePath(accountID: String, path: String) async throws -> SolanaReceiveState {
        try await pool.write { db in
            guard let state = try Self.solanaReceiveState(accountID: accountID, db: db),
                  state.addresses.contains(where: { $0.path == path }) else { throw StoreError.missingRecord }
            if state.selected.path != path {
                // Fence in-flight work even after A -> B -> A selection changes.
                try db.execute(sql: "UPDATE walletAccounts SET syncGeneration=syncGeneration+1 WHERE id=?", arguments: [accountID])
            }
            try db.execute(sql: "UPDATE solanaReceiveAddresses SET isSelected=0 WHERE accountID=? AND isSelected=1", arguments: [accountID])
            try db.execute(sql: "UPDATE solanaReceiveAddresses SET isSelected=1 WHERE accountID=? AND path=?", arguments: [accountID, path])
            return try Self.solanaReceiveState(accountID: accountID, db: db)!
        }
    }

    private static func solanaReceiveState(accountID: String, db: Database) throws -> SolanaReceiveState? {
        let rows = try Row.fetchAll(db, sql: "SELECT path,address,isSelected FROM solanaReceiveAddresses WHERE accountID=?", arguments: [accountID])
        guard !rows.isEmpty else { return nil }
        let addresses = rows.map { SolanaReceiveAddress(path: $0["path"], address: $0["address"]) }.sorted {
            func rank(_ address: SolanaReceiveAddress) -> Int {
                switch address.derivation { case .phantom: 0; case .trustWallet: 1; case nil: 2 }
            }
            return rank($0) == rank($1) ? $0.path < $1.path : rank($0) < rank($1)
        }
        let selected = rows.filter { ($0["isSelected"] as Bool) }
        guard selected.count == 1 else { throw StoreError.conflictingIdentity }
        return .init(addresses: addresses, selected: .init(path: selected[0]["path"], address: selected[0]["address"]))
    }
}
