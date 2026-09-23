import CryptoKit
import Foundation
import GRDB

enum EVMApprovalKind: String, Codable, Hashable, Sendable {
    case tokenAllowance = "token_allowance"
    case nftToken = "nft_token"
    case operatorAccess = "operator_access"
}

struct EVMOnChainApproval: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let accountID: String
    let networkID: String
    let ownerAddress: String
    let contractAddress: String
    let spenderAddress: String
    let kind: EVMApprovalKind
    let tokenID: String?
    let amountAtomic: String?
    let tokenName: String?
    let tokenSymbol: String?
    let decimals: Int?
    let transactionHash: String?
    let blockNumber: String?
    let discoveredAt: Date
    let lastValidatedAt: Date
    let pendingRevocationTransactionHash: String?
    let pendingRevocationSubmittedAt: Date?

    static func stableID(
        accountID: String,
        networkID: String,
        contractAddress: String,
        spenderAddress: String,
        kind: EVMApprovalKind,
        tokenID: String?
    ) -> String {
        let identity: String
        if kind == .nftToken {
            identity = [
                accountID,
                networkID,
                contractAddress.lowercased(),
                kind.rawValue,
                tokenID ?? ""
            ].joined(separator: "|")
        } else {
            identity = [
                accountID,
                networkID,
                contractAddress.lowercased(),
                spenderAddress.lowercased(),
                kind.rawValue
            ].joined(separator: "|")
        }
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct EVMLocalDAppSession: Hashable, Identifiable, Sendable {
    let id: String
    let origin: String
    let name: String
    let iconURL: URL?
    let lastUsedAt: Date
    let accountCount: Int
    let networkCount: Int
}

struct EVMAccessWalletContext: Sendable {
    let walletID: String
    let accounts: [DBWalletAccountRecord]

    var isAvailable: Bool { !accounts.isEmpty }
}

private struct DBEVMApprovalRecord:
    Codable,
    FetchableRecord,
    PersistableRecord,
    Sendable
{
    static let databaseTableName = "evmApprovals"

    let id: String
    let accountID: String
    let networkID: String
    let ownerAddress: String
    let contractAddress: String
    let spenderAddress: String
    let kind: String
    let tokenID: String?
    let amountAtomic: String?
    let tokenName: String?
    let tokenSymbol: String?
    let decimals: Int?
    let transactionHash: String?
    let blockNumber: String?
    var isActive: Bool
    let discoveredAt: Double
    var lastValidatedAt: Double
    var pendingRevocationTransactionHash: String?
    var pendingRevocationSubmittedAt: Double?

    init(
        approval: EVMOnChainApproval,
        existing: DBEVMApprovalRecord? = nil
    ) {
        id = approval.id
        accountID = approval.accountID
        networkID = approval.networkID
        ownerAddress = approval.ownerAddress.lowercased()
        contractAddress = approval.contractAddress.lowercased()
        spenderAddress = approval.spenderAddress.lowercased()
        kind = approval.kind.rawValue
        tokenID = approval.tokenID
        amountAtomic = approval.amountAtomic
        tokenName = approval.tokenName
        tokenSymbol = approval.tokenSymbol
        decimals = approval.decimals
        transactionHash = approval.transactionHash?.lowercased()
        blockNumber = approval.blockNumber
        isActive = true
        discoveredAt = existing?.discoveredAt
            ?? approval.discoveredAt.timeIntervalSince1970
        lastValidatedAt = approval.lastValidatedAt.timeIntervalSince1970
        pendingRevocationTransactionHash =
            existing?.pendingRevocationTransactionHash
                ?? approval.pendingRevocationTransactionHash
        pendingRevocationSubmittedAt =
            existing?.pendingRevocationSubmittedAt
                ?? approval.pendingRevocationSubmittedAt?
                    .timeIntervalSince1970
    }

    var approval: EVMOnChainApproval? {
        guard let approvalKind = EVMApprovalKind(rawValue: kind) else {
            return nil
        }
        return EVMOnChainApproval(
            id: id,
            accountID: accountID,
            networkID: networkID,
            ownerAddress: ownerAddress,
            contractAddress: contractAddress,
            spenderAddress: spenderAddress,
            kind: approvalKind,
            tokenID: tokenID,
            amountAtomic: amountAtomic,
            tokenName: tokenName,
            tokenSymbol: tokenSymbol,
            decimals: decimals,
            transactionHash: transactionHash,
            blockNumber: blockNumber,
            discoveredAt: Date(timeIntervalSince1970: discoveredAt),
            lastValidatedAt: Date(
                timeIntervalSince1970: lastValidatedAt
            ),
            pendingRevocationTransactionHash:
                pendingRevocationTransactionHash,
            pendingRevocationSubmittedAt: pendingRevocationSubmittedAt.map {
                Date(timeIntervalSince1970: $0)
            }
        )
    }
}

extension WalletDatabase {
    static func registerEVMApprovalMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v60_evm_approvals") { database in
            try database.execute(
                sql: """
                CREATE TABLE evmApprovals (
                    id TEXT PRIMARY KEY NOT NULL,
                    accountID TEXT NOT NULL
                        REFERENCES walletAccounts(id) ON DELETE CASCADE,
                    networkID TEXT NOT NULL
                        REFERENCES networks(id) ON DELETE CASCADE,
                    ownerAddress TEXT NOT NULL,
                    contractAddress TEXT NOT NULL,
                    spenderAddress TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK (
                        kind IN (
                            'token_allowance',
                            'nft_token',
                            'operator_access'
                        )
                    ),
                    tokenID TEXT CHECK (
                        tokenID IS NULL OR (
                            length(tokenID) > 0
                            AND tokenID NOT GLOB '*[^0-9]*'
                        )
                    ),
                    amountAtomic TEXT CHECK (
                        amountAtomic IS NULL OR (
                            length(amountAtomic) > 0
                            AND amountAtomic NOT GLOB '*[^0-9]*'
                        )
                    ),
                    tokenName TEXT,
                    tokenSymbol TEXT,
                    decimals INTEGER CHECK (
                        decimals IS NULL OR decimals BETWEEN 0 AND 255
                    ),
                    transactionHash TEXT,
                    blockNumber TEXT CHECK (
                        blockNumber IS NULL OR (
                            length(blockNumber) > 0
                            AND blockNumber NOT GLOB '*[^0-9]*'
                        )
                    ),
                    isActive INTEGER NOT NULL DEFAULT 1,
                    discoveredAt REAL NOT NULL,
                    lastValidatedAt REAL NOT NULL,
                    pendingRevocationTransactionHash TEXT,
                    pendingRevocationSubmittedAt REAL
                );

                CREATE INDEX evmApprovals_account_active
                    ON evmApprovals(accountID, isActive, networkID);
                CREATE INDEX evmApprovals_spender
                    ON evmApprovals(networkID, spenderAddress, isActive);
                """
            )
        }
    }

    func selectedWalletEVMAccessContext() async throws
        -> EVMAccessWalletContext? {
        guard let identity = try await selectedWalletIdentity() else {
            return nil
        }
        let capabilities = try await walletCapabilities(
            walletID: identity.walletID
        )
        guard capabilities.usesEVMWalletAddress else { return nil }
        let accounts = try await pool.read { database in
            try DBWalletAccountRecord
                .filter(Column("walletID") == identity.walletID)
                .filter(Column("isEnabled") == true)
                .filter(Column("isWatchOnly") == false)
                .fetchAll(database)
                .filter {
                    ReceiveNetworkCatalog.network(
                        for: $0.networkID
                    )?.blockchain.isEVM == true
                }
        }
        guard !accounts.isEmpty else { return nil }
        return EVMAccessWalletContext(
            walletID: identity.walletID,
            accounts: accounts
        )
    }

    func activeEVMApprovals(accountIDs: [String]) async throws
        -> [EVMOnChainApproval] {
        guard !accountIDs.isEmpty else { return [] }
        return try await pool.read { database in
            let records = try DBEVMApprovalRecord
                .filter(accountIDs.contains(Column("accountID")))
                .filter(Column("isActive") == true)
                .order(Column("networkID"), Column("lastValidatedAt").desc)
                .fetchAll(database)
            return records.compactMap(\.approval)
        }
    }

    func reconcileEVMApprovals(
        accountID: String,
        networkID: String,
        active approvals: [EVMOnChainApproval],
        inactiveIDs: Set<String>
    ) async throws {
        try await pool.write { database in
            if !inactiveIDs.isEmpty {
                try database.execute(
                    sql: """
                    UPDATE evmApprovals
                    SET isActive = 0,
                        pendingRevocationTransactionHash = NULL,
                        pendingRevocationSubmittedAt = NULL
                    WHERE accountID = ?
                      AND networkID = ?
                      AND id IN (\(inactiveIDs.map { _ in "?" }.joined(separator: ",")))
                    """,
                    arguments: StatementArguments(
                        [accountID, networkID] + inactiveIDs.sorted()
                    )
                )
            }
            for approval in approvals where
                approval.accountID == accountID
                    && approval.networkID == networkID {
                let existing = try DBEVMApprovalRecord.fetchOne(
                    database,
                    key: approval.id
                )
                try DBEVMApprovalRecord(
                    approval: approval,
                    existing: existing
                ).save(database)
            }
        }
    }

    func markEVMApprovalRevocationSubmitted(
        approvalID: String,
        transactionHash: String,
        submittedAt: Date
    ) async throws {
        try await pool.write { database in
            try database.execute(
                sql: """
                UPDATE evmApprovals
                SET pendingRevocationTransactionHash = ?,
                    pendingRevocationSubmittedAt = ?
                WHERE id = ? AND isActive = 1
                """,
                arguments: [
                    transactionHash.lowercased(),
                    submittedAt.timeIntervalSince1970,
                    approvalID
                ]
            )
        }
    }

    func selectedWalletDAppSessions(
        accountIDs: [String]
    ) async throws -> [EVMLocalDAppSession] {
        guard !accountIDs.isEmpty else { return [] }
        return try await pool.read { database in
            let placeholders = accountIDs.map { _ in "?" }
                .joined(separator: ",")
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT d.id, d.origin, d.name, d.iconURL, d.lastUsedAt,
                       COUNT(DISTINCT p.accountID) AS accountCount,
                       COUNT(DISTINCT p.chainID) AS networkCount
                FROM connectedDApps d
                JOIN dappPermissions p ON p.dappID = d.id
                WHERE p.accountID IN (\(placeholders))
                  AND (d.expiresAt IS NULL OR d.expiresAt > ?)
                GROUP BY d.id, d.origin, d.name, d.iconURL, d.lastUsedAt
                ORDER BY d.lastUsedAt DESC
                """,
                arguments: StatementArguments(
                    accountIDs + [String(Date().timeIntervalSince1970)]
                )
            )
            return rows.map { row in
                let iconText: String? = row["iconURL"]
                return EVMLocalDAppSession(
                    id: row["id"],
                    origin: row["origin"],
                    name: row["name"],
                    iconURL: iconText.flatMap(URL.init(string:)),
                    lastUsedAt: Date(
                        timeIntervalSince1970: row["lastUsedAt"]
                    ),
                    accountCount: row["accountCount"],
                    networkCount: row["networkCount"]
                )
            }
        }
    }
}
