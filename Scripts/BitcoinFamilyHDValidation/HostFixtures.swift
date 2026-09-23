// Host-only adapters for unrelated app/UI/Keychain dependencies. The HD,
// database migration, discovery and signer implementations are production files.
import Foundation
import GRDB
import WalletCore

enum WalletBlockchain { case bitcoin, bitcoincash, litecoin, dogecoin }
enum WalletLocalization { static func string(_ key: String) -> String { key } }
enum EnglishNumbers { static func localized(_ key: String, _ value: Any) -> String { key } }
enum PrivateKeyImportFormat { case extendedLegacy, extendedNestedSegwit, extendedNativeSegwit }
enum ElectrumSeedKind { case standard, segwit
    var accountPath: String { self == .standard ? "m" : "m/0'" }
}
struct WalletRecoveryCredential: Sendable {
    let mnemonic: String
    var passphrase = ""
    var electrumKind: ElectrumSeedKind? = nil
    func makeHDWallet() -> HDWallet? { HDWallet(mnemonic: mnemonic, passphrase: passphrase) }
}
struct SendDraft { var usesMaximumBalance = false }
struct SendResolvedSigningMaterial { let bitcoinHDRecoveryCredential: WalletRecoveryCredential? }
struct BitcoinSilentPaymentOutput: Hashable, Sendable { let scriptPubKey: Data }
struct MuunRecoveryDerivedAddress: Hashable, Sendable { let scriptPubKey: Data }
enum SendNetworkFeeQuoteModel: Hashable, Sendable { case satoshiPerByte }
enum SendTransactionSubmissionError: Error {
    case invalidAmount, invalidRecipient, amountOutOfRange, derivedAddressMismatch, secretUnavailable
    case insufficientAssetBalance, insufficientNetworkFeeBalance
    case feeQuoteUnavailable(String), signing(code: String, message: String)
    static func sanitizedMessage(_ message: String) -> String { message }
}
enum BitcoinFamilyAPIError: Error { case invalidResponse }
enum DatabaseWalletKind: String { case created, importedRecoveryPhrase, importedPrivateKey }
struct DBWalletRecord: Codable, FetchableRecord, TableRecord { static let databaseTableName = "wallets"; let id: String; let kind: String }
struct DBWalletAccountRecord: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "walletAccounts"
    let walletID: String; let networkID: String; let isEnabled: Bool
}
struct WalletSecretVault: Sendable { static let shared = Self() }
enum WalletDatabaseRuntime { static func require() throws -> WalletDatabase { throw BitcoinHDWalletDatabaseError.walletUnavailable } }
final class WalletDatabase: @unchecked Sendable {
    let pool: DatabasePool
    let credential: WalletRecoveryCredential
    init(credential: WalletRecoveryCredential) throws {
        self.credential = credential
        pool = try DatabasePool(path: NSTemporaryDirectory() + UUID().uuidString + ".sqlite")
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE wallets (id TEXT PRIMARY KEY, kind TEXT NOT NULL);
                CREATE TABLE networks (id TEXT PRIMARY KEY);
                CREATE TABLE walletAccounts (walletID TEXT, networkID TEXT, isEnabled INTEGER);
                CREATE TABLE publishedBalances (walletID TEXT, networkID TEXT, balance TEXT,
                    PRIMARY KEY (walletID, networkID));
                INSERT INTO wallets VALUES ('fixture', 'importedRecoveryPhrase');
                """)
            for chain in [BitcoinFamilyChain.dogecoin, .litecoin, .bitcoinCash] {
                try db.execute(sql: "INSERT INTO networks VALUES (?)", arguments: [chain.networkID])
                try db.execute(sql: "INSERT INTO walletAccounts VALUES ('fixture', ?, 1)", arguments: [chain.networkID])
            }
        }
        var migrator = DatabaseMigrator()
        Self.registerBitcoinFamilyHDMigration(on: &migrator)
        try migrator.migrate(pool)
    }
    func loadRecoveryCredential(walletID: String, vault: WalletSecretVault) async throws -> WalletRecoveryCredential { credential }
    func saveBitcoinFamilyBalance(_ balance: BitcoinFamilyAtomicInteger, material: BitcoinFamilyAccountMaterial,
                                 walletID: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO publishedBalances VALUES (?, ?, ?)",
                           arguments: [walletID, material.chain.networkID, balance.decimalText])
        }
    }
}

struct HostBatchResult: Sendable { let parameter: String; let value: JSONValue }
final class BitcoinFamilyElectrumClient: @unchecked Sendable {
    typealias Handler = @Sendable (BitcoinFamilyChain, String, String) async throws -> JSONValue
    static let maximumHistoryResponseBytes = 8_388_608
    static let shared = BitcoinFamilyElectrumClient()
    private let handler: Handler?
    private let connections = HostElectrumConnections()
    init(handler: Handler? = nil) { self.handler = handler }

    func callStringParameterBatch(chain: BitcoinFamilyChain, method: String, parameters: [String],
        maximumResponseBytes: Int = 1_048_576) async throws -> [HostBatchResult] {
        try await withThrowingTaskGroup(of: HostBatchResult.self) { group in
            for parameter in parameters {
                group.addTask {
                    let value: JSONValue
                    if let handler = self.handler { value = try await handler(chain, method, parameter) }
                    else { value = try await self.call(chain: chain, method: method, parameter: parameter) }
                    return HostBatchResult(parameter: parameter, value: value)
                }
            }
            var results: [HostBatchResult] = []
            for try await value in group { results.append(value) }
            return results
        }
    }
    func call(chain: BitcoinFamilyChain, method: String, parameter: String = "") async throws -> JSONValue {
        if let handler { return try await handler(chain, method, parameter) }
        var last: Error = BitcoinFamilyElectrumError.unavailable
        for (host, port) in chain.endpoints {
            do {
                let connection = await connections.connection(host: host, port: port)
                let id = await connections.nextID()
                let params: [AnyEncodable]
                if method == "server.features" || method == "blockchain.headers.subscribe" { params = [] }
                else { params = try hostRPCParameters(chain: chain, method: method, parameter: parameter) }
                var payload = try JSONEncoder().encode(ElectrumRequest(id: id, method: method, params: params))
                payload.append(10)
                return try await connection.request(id: id, payload: payload, maximumResponseBytes: 8_388_608)
            } catch { last = error }
        }
        throw last
    }

    func callRankedRead(chain: BitcoinFamilyChain, method: String, params: [AnyEncodable], maximumResponseBytes: Int,
                        rating: @escaping @Sendable (JSONValue) throws -> BitcoinFamilyElectrumReadRating) async throws -> JSONValue {
        let encoded = try JSONEncoder().encode(params)
        let arguments = try JSONSerialization.jsonObject(with: encoded) as! [String]
        if let handler { return try await handler(chain, method + "#ranked", arguments[0]) }
        return try await call(chain: chain, method: method, parameter: arguments[0])
    }
}
actor HostElectrumConnections {
    var connections: [String: PersistentElectrumConnection] = [:]
    var id = 0
    func nextID() -> Int { id += 1; return id }
    func connection(host: String, port: UInt16) -> PersistentElectrumConnection {
        let key = "\(host):\(port)"
        if let connection = connections[key] { return connection }
        let connection = PersistentElectrumConnection(host: host, port: port)
        connections[key] = connection
        return connection
    }
}
