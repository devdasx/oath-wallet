import Foundation
import GRDB

enum WalletSecureCleanupScope: String, Codable, Sendable {
    case appReset = "app_reset"
    case walletRemoval = "wallet_removal"
}

enum WalletSecureCleanupJobKind: String, Codable, Sendable {
    case walletSecret = "wallet_secret"
    case passcodeCredential = "passcode_credential"
    case pushInstallation = "push_installation"
}

enum WalletSecureCleanupState: String, Codable, Sendable {
    case pending
    case complete
}

enum WalletSecureCleanupMaintenanceState:
    String, Codable, Sendable
{
    case notRequired = "not_required"
    case pending
    case complete
    case failed
}

struct WalletAppResetCleanupPlan: Equatable, Sendable {
    let secretReferences: [String]
    let requiresPushCleanup: Bool

    static let empty = WalletAppResetCleanupPlan(
        secretReferences: [],
        requiresPushCleanup: false
    )

    init(
        secretReferences: [String],
        requiresPushCleanup: Bool
    ) {
        self.secretReferences = Array(
            Set(secretReferences.filter { !$0.isEmpty })
        ).sorted()
        self.requiresPushCleanup = requiresPushCleanup
    }
}

struct WalletAppResetCommit: Equatable, Sendable {
    let operationID: UUID
}

struct WalletSecureCleanupDrainResult: Equatable, Sendable {
    let completedCount: Int
    let pendingCount: Int
    let lastErrorCode: String?
}

protocol WalletSecureCleanupVault: Sendable {
    func allReferences() throws -> [String]
    func deleteIfPresent(reference: String) throws
    func deletePasscodeCredential(reference: String) throws
}

struct DBSecureCleanupOperationRecord:
    Codable, FetchableRecord, PersistableRecord, Sendable
{
    static let databaseTableName = "secureCleanupOperations"

    let id: String
    let scope: String
    var cleanupState: String
    var maintenanceState: String
    var maintenanceErrorCode: String?
    let committedAt: Double
    var updatedAt: Double
}

struct DBSecureCleanupJobRecord:
    Codable, FetchableRecord, PersistableRecord, Sendable
{
    static let databaseTableName = "secureCleanupJobs"

    let id: String
    let operationID: String
    let kind: String
    let opaqueReference: String?
    var attemptCount: Int
    var lastAttemptAt: Double?
    var lastErrorCode: String?
    let createdAt: Double
    var updatedAt: Double
}

enum WalletSecureCleanupErrorCode {

    static func errorCode(for error: Error) -> String {
        if let vaultError = error as? WalletSecretVaultError {
            return sanitize(vaultError.diagnosticDescription)
        }
        if let pushError = error as? PushInstallationVaultError {
            return sanitize(pushError.diagnosticCode)
        }
        if let databaseError = error as? DatabaseError {
            return "sqlite_\(databaseError.extendedResultCode.rawValue)"
        }
        return sanitize(String(reflecting: type(of: error)))
    }

    private static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_.-")
        )
        let filtered = value.unicodeScalars
            .filter { allowed.contains($0) }
            .prefix(96)
        return String(filtered.map(Character.init))
    }
}

extension WalletDatabase {
    static func insertSecureCleanupOperation(
        in database: Database,
        operationID: UUID,
        scope: WalletSecureCleanupScope,
        jobs: [
            (
                kind: WalletSecureCleanupJobKind,
                opaqueReference: String?
            )
        ],
        requiresMaintenance: Bool,
        now: Double
    ) throws {
        let uniqueJobs = Dictionary(
            jobs.map {
                (
                    "\($0.kind.rawValue):\($0.opaqueReference ?? "")",
                    $0
                )
            },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted {
            let first = "\($0.kind.rawValue):\($0.opaqueReference ?? "")"
            let second = "\($1.kind.rawValue):\($1.opaqueReference ?? "")"
            return first < second
        }
        let operationIDString = operationID.uuidString.lowercased()
        try DBSecureCleanupOperationRecord(
            id: operationIDString,
            scope: scope.rawValue,
            cleanupState: uniqueJobs.isEmpty
                ? WalletSecureCleanupState.complete.rawValue
                : WalletSecureCleanupState.pending.rawValue,
            maintenanceState: requiresMaintenance
                ? WalletSecureCleanupMaintenanceState.pending.rawValue
                : WalletSecureCleanupMaintenanceState.notRequired.rawValue,
            maintenanceErrorCode: nil,
            committedAt: now,
            updatedAt: now
        ).insert(database)

        for job in uniqueJobs {
            try DBSecureCleanupJobRecord(
                id: UUID().uuidString.lowercased(),
                operationID: operationIDString,
                kind: job.kind.rawValue,
                opaqueReference: job.opaqueReference,
                attemptCount: 0,
                lastAttemptAt: nil,
                lastErrorCode: nil,
                createdAt: now,
                updatedAt: now
            ).insert(database)
        }
    }

    func retryPendingSecretCleanup(
        vault: any WalletSecureCleanupVault
    ) async -> WalletSecureCleanupDrainResult {
        let jobs: [DBSecureCleanupJobRecord]
        do {
            jobs = try await pool.read { database in
                try DBSecureCleanupJobRecord.fetchAll(
                    database,
                    sql: """
                    SELECT *
                    FROM secureCleanupJobs
                    WHERE kind IN (?, ?)
                    ORDER BY createdAt, id
                    """,
                    arguments: [
                        WalletSecureCleanupJobKind
                            .walletSecret.rawValue,
                        WalletSecureCleanupJobKind
                            .passcodeCredential.rawValue
                    ]
                )
            }
        } catch {
            let code = WalletSecureCleanupErrorCode.errorCode(for: error)
            return WalletSecureCleanupDrainResult(
                completedCount: 0,
                pendingCount: 1,
                lastErrorCode: code
            )
        }

        var completedCount = 0
        var lastErrorCode: String?
        for job in jobs {
            guard let kind = WalletSecureCleanupJobKind(
                rawValue: job.kind
            ) else {
                let code = "invalid_job_kind"
                await recordSecureCleanupFailure(job: job, code: code)
                lastErrorCode = code
                continue
            }
            guard let reference = job.opaqueReference,
                  !reference.isEmpty else {
                let code = "missing_opaque_reference"
                await recordSecureCleanupFailure(job: job, code: code)
                lastErrorCode = code
                continue
            }

            do {
                switch kind {
                case .walletSecret:
                    try vault.deleteIfPresent(reference: reference)
                case .passcodeCredential:
                    try vault.deletePasscodeCredential(
                        reference: reference
                    )
                case .pushInstallation:
                    continue
                }
                try await completeSecureCleanupJob(job)
                completedCount += 1
            } catch {
                let code = WalletSecureCleanupErrorCode.errorCode(
                    for: error
                )
                await recordSecureCleanupFailure(job: job, code: code)
                lastErrorCode = code
            }
        }

        let pendingCount = await pendingSecureCleanupJobCount(
            kinds: [.walletSecret, .passcodeCredential]
        )
        return WalletSecureCleanupDrainResult(
            completedCount: completedCount,
            pendingCount: pendingCount,
            lastErrorCode: lastErrorCode
        )
    }

    func pendingPushCleanupJobs() async throws
        -> [DBSecureCleanupJobRecord]
    {
        try await pool.read { database in
            try DBSecureCleanupJobRecord.fetchAll(
                database,
                sql: """
                SELECT *
                FROM secureCleanupJobs
                WHERE kind = ?
                ORDER BY createdAt, id
                """,
                arguments: [
                    WalletSecureCleanupJobKind.pushInstallation.rawValue
                ]
            )
        }
    }

    func completePushCleanupJobs(
        _ jobs: [DBSecureCleanupJobRecord]
    ) async {
        for job in jobs {
            do {
                try await completeSecureCleanupJob(job)
            } catch {
            }
        }
    }

    func failPushCleanupJobs(
        _ jobs: [DBSecureCleanupJobRecord],
        errorCode: String
    ) async {
        for job in jobs {
            await recordSecureCleanupFailure(
                job: job,
                code: errorCode
            )
        }
    }

    func appResetOperationsRequiringMaintenance() async
        -> [DBSecureCleanupOperationRecord]
    {
        do {
            return try await pool.read { database in
                try DBSecureCleanupOperationRecord.fetchAll(
                    database,
                    sql: """
                    SELECT *
                    FROM secureCleanupOperations
                    WHERE scope = ?
                      AND maintenanceState IN (?, ?)
                    ORDER BY committedAt, id
                    """,
                    arguments: [
                        WalletSecureCleanupScope.appReset.rawValue,
                        WalletSecureCleanupMaintenanceState
                            .pending.rawValue,
                        WalletSecureCleanupMaintenanceState
                            .failed.rawValue
                    ]
                )
            }
        } catch {
            return []
        }
    }

    func recordResetMaintenance(
        operationID: UUID,
        state: WalletSecureCleanupMaintenanceState,
        errorCode: String?
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            try database.execute(
                sql: """
                UPDATE secureCleanupOperations
                SET maintenanceState = ?,
                    maintenanceErrorCode = ?,
                    updatedAt = ?
                WHERE id = ? AND scope = ?
                """,
                arguments: [
                    state.rawValue,
                    errorCode,
                    now,
                    operationID.uuidString.lowercased(),
                    WalletSecureCleanupScope.appReset.rawValue
                ]
            )
        }
    }

    func secureCleanupOperation(
        id: UUID
    ) async throws -> DBSecureCleanupOperationRecord? {
        try await pool.read { database in
            try DBSecureCleanupOperationRecord.fetchOne(
                database,
                key: id.uuidString.lowercased()
            )
        }
    }

    func pendingSecureCleanupJobs(
        operationID: UUID
    ) async throws -> [DBSecureCleanupJobRecord] {
        try await pool.read { database in
            try DBSecureCleanupJobRecord
                .filter(
                    Column("operationID")
                        == operationID.uuidString.lowercased()
                )
                .order(Column("createdAt"), Column("id"))
                .fetchAll(database)
        }
    }

    private func completeSecureCleanupJob(
        _ job: DBSecureCleanupJobRecord
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            try DBSecureCleanupJobRecord.deleteOne(
                database,
                key: job.id
            )
            try Self.refreshSecureCleanupOperationState(
                database: database,
                operationID: job.operationID,
                now: now
            )
        }
    }

    private func recordSecureCleanupFailure(
        job: DBSecureCleanupJobRecord,
        code: String
    ) async {
        let now = Date().timeIntervalSince1970
        do {
            try await pool.write { database in
                try database.execute(
                    sql: """
                    UPDATE secureCleanupJobs
                    SET attemptCount = attemptCount + 1,
                        lastAttemptAt = ?,
                        lastErrorCode = ?,
                        updatedAt = ?
                    WHERE id = ?
                    """,
                    arguments: [now, code, now, job.id]
                )
            }
        } catch {
        }
    }

    private func pendingSecureCleanupJobCount(
        kinds: [WalletSecureCleanupJobKind]
    ) async -> Int {
        guard !kinds.isEmpty else { return 0 }
        do {
            return try await pool.read { database in
                let rawValues = kinds.map(\.rawValue)
                return try DBSecureCleanupJobRecord
                    .filter(rawValues.contains(Column("kind")))
                    .fetchCount(database)
            }
        } catch {
            return 1
        }
    }

    private static func refreshSecureCleanupOperationState(
        database: Database,
        operationID: String,
        now: Double
    ) throws {
        let pendingCount = try DBSecureCleanupJobRecord
            .filter(Column("operationID") == operationID)
            .fetchCount(database)
        try database.execute(
            sql: """
            UPDATE secureCleanupOperations
            SET cleanupState = ?, updatedAt = ?
            WHERE id = ?
            """,
            arguments: [
                pendingCount == 0
                    ? WalletSecureCleanupState.complete.rawValue
                    : WalletSecureCleanupState.pending.rawValue,
                now,
                operationID
            ]
        )
    }
}
