import Foundation
import GRDB

enum AppReviewPromptResponse: String, Codable, Equatable, Sendable {
    case enjoying
    case notEnjoying = "not_enjoying"
    case dismissed
}

struct AppReviewPromptSnapshot: Equatable, Sendable {
    let accumulatedActiveMilliseconds: Int64
    let promptPresentedAt: Date?
    let response: AppReviewPromptResponse?
    let feedbackSubmittedAt: Date?

    var wasPresented: Bool {
        promptPresentedAt != nil
    }
}

private struct DBAppReviewPromptStateRecord:
    Codable,
    FetchableRecord,
    PersistableRecord,
    Sendable
{
    static let databaseTableName = "appReviewPromptState"

    let id: Int
    var accumulatedActiveMilliseconds: Int64
    var promptPresentedAt: Double?
    var response: String?
    var feedbackSubmittedAt: Double?
    var updatedAt: Double

    var snapshot: AppReviewPromptSnapshot {
        AppReviewPromptSnapshot(
            accumulatedActiveMilliseconds:
                accumulatedActiveMilliseconds,
            promptPresentedAt: promptPresentedAt.map(
                Date.init(timeIntervalSince1970:)
            ),
            response: response.flatMap(AppReviewPromptResponse.init),
            feedbackSubmittedAt: feedbackSubmittedAt.map(
                Date.init(timeIntervalSince1970:)
            )
        )
    }
}

extension WalletDatabase {
    private static let appReviewPromptSingletonID = 1

    static func registerAppReviewPromptMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v47_app_review_prompt_state"
        ) { database in
            try database.execute(
                sql: """
                CREATE TABLE appReviewPromptState (
                    id INTEGER PRIMARY KEY NOT NULL
                        CHECK (id = 1),
                    accumulatedActiveMilliseconds INTEGER NOT NULL
                        DEFAULT 0
                        CHECK (accumulatedActiveMilliseconds >= 0),
                    promptPresentedAt REAL,
                    response TEXT
                        CHECK (
                            response IS NULL
                            OR response IN (
                                'enjoying',
                                'not_enjoying',
                                'dismissed'
                            )
                        ),
                    feedbackSubmittedAt REAL,
                    updatedAt REAL NOT NULL
                );

                INSERT INTO appReviewPromptState (
                    id,
                    accumulatedActiveMilliseconds,
                    updatedAt
                ) VALUES (1, 0, strftime('%s', 'now'));
                """
            )
        }
    }

    func appReviewPromptSnapshot() async throws
        -> AppReviewPromptSnapshot {
        try await pool.read { database in
            try Self.appReviewPromptRecord(in: database).snapshot
        }
    }

    func addAppReviewActiveUsage(
        milliseconds: Int64,
        now: Date = Date()
    ) async throws -> AppReviewPromptSnapshot {
        guard milliseconds > 0 else {
            return try await appReviewPromptSnapshot()
        }

        return try await pool.write { database in
            var record = try Self.appReviewPromptRecord(in: database)
            guard record.promptPresentedAt == nil else {
                return record.snapshot
            }

            let remainingCapacity = Int64.max
                - record.accumulatedActiveMilliseconds
            record.accumulatedActiveMilliseconds += min(
                milliseconds,
                remainingCapacity
            )
            record.updatedAt = now.timeIntervalSince1970
            try record.update(database)
            return record.snapshot
        }
    }

    func claimAppReviewPromptPresentation(
        thresholdMilliseconds: Int64,
        now: Date = Date()
    ) async throws -> Bool {
        guard thresholdMilliseconds > 0 else { return false }

        return try await pool.write { database in
            var record = try Self.appReviewPromptRecord(in: database)
            guard record.promptPresentedAt == nil,
                  record.accumulatedActiveMilliseconds
                    >= thresholdMilliseconds else {
                return false
            }

            record.promptPresentedAt = now.timeIntervalSince1970
            record.updatedAt = now.timeIntervalSince1970
            try record.update(database)
            return true
        }
    }

    func recordAppReviewPromptResponse(
        _ response: AppReviewPromptResponse,
        now: Date = Date()
    ) async throws {
        try await pool.write { database in
            var record = try Self.appReviewPromptRecord(in: database)
            guard record.promptPresentedAt != nil,
                  record.response == nil else {
                return
            }
            record.response = response.rawValue
            record.updatedAt = now.timeIntervalSince1970
            try record.update(database)
        }
    }

    func markAppReviewFeedbackSubmitted(
        now: Date = Date()
    ) async throws {
        try await pool.write { database in
            var record = try Self.appReviewPromptRecord(in: database)
            guard record.promptPresentedAt != nil else { return }
            record.feedbackSubmittedAt = now.timeIntervalSince1970
            record.updatedAt = now.timeIntervalSince1970
            try record.update(database)
        }
    }

    private static func appReviewPromptRecord(
        in database: Database
    ) throws -> DBAppReviewPromptStateRecord {
        if let record = try DBAppReviewPromptStateRecord.fetchOne(
            database,
            key: appReviewPromptSingletonID
        ) {
            return record
        }

        let now = Date().timeIntervalSince1970
        let record = DBAppReviewPromptStateRecord(
            id: appReviewPromptSingletonID,
            accumulatedActiveMilliseconds: 0,
            promptPresentedAt: nil,
            response: nil,
            feedbackSubmittedAt: nil,
            updatedAt: now
        )
        try record.insert(database)
        return record
    }
}
