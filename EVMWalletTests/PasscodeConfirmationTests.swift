import Foundation
import GRDB
import Testing
import SwiftUI
@testable import Aperture

struct PasscodeConfirmationTests {
    @Test
    func passcodeEntryControlsAlwaysUseLeftToRightOrdering() {
        #expect(
            PasscodeEntryControlLayout.direction == .leftToRight
        )
    }

    @Test
    func passcodeSetupStepsUseOppositeSemanticSlideEdges() {
        #expect(
            PasscodeStepReplacementPosition.entry.insertionEdge
                == .leading
        )
        #expect(
            PasscodeStepReplacementPosition.entry.removalEdge
                == .leading
        )
        #expect(
            PasscodeStepReplacementPosition.intermediate.insertionEdge
                == .trailing
        )
        #expect(
            PasscodeStepReplacementPosition.intermediate.removalEdge
                == .leading
        )
        #expect(
            PasscodeStepReplacementPosition.confirmation.insertionEdge
                == .trailing
        )
        #expect(
            PasscodeStepReplacementPosition.confirmation.removalEdge
                == .trailing
        )
    }

    @Test
    func matchingConfirmationIsAccepted() {
        #expect(
            PasscodeConfirmation.matches(
                confirmation: "829104",
                original: "829104"
            )
        )
    }

    @Test
    func mismatchedConfirmationIsRejected() {
        #expect(
            !PasscodeConfirmation.matches(
                confirmation: "829105",
                original: "829104"
            )
        )
    }

    @Test
    func invalidPasscodeShapesCannotMatch() {
        #expect(!PasscodeConfirmation.matches(
            confirmation: "12345",
            original: "12345"
        ))
        #expect(!PasscodeConfirmation.matches(
            confirmation: "1234567",
            original: "1234567"
        ))
        #expect(!PasscodeConfirmation.matches(
            confirmation: "１２３４５６",
            original: "１２３４５６"
        ))
    }

    @Test
    func rapidInputSubmitsExactlyOnceAtSixASCIIDigits() {
        var input = PasscodeInputBuffer(length: 6)
        var submissions: [String] = []

        for digit in ["1", "2", "3", "4", "5", "6", "7", "8"] {
            if let passcode = input.append(digit) {
                submissions.append(passcode)
            }
        }

        #expect(input.value == "123456")
        #expect(input.hasSubmitted)
        #expect(submissions == ["123456"])
    }

    @Test
    func resetStartsANewIndependentInputSession() {
        var input = PasscodeInputBuffer(length: 6)
        for digit in ["8", "2", "9", "1", "0", "4"] {
            _ = input.append(digit)
        }

        input.reset()

        #expect(input.value.isEmpty)
        #expect(!input.hasSubmitted)
        #expect(input.append("5") == nil)
        #expect(input.value == "5")
    }

    @Test
    func passcodeLockoutUsesTheExactEscalationAndSixHourCap() {
        #expect(WalletPasscodeLockoutPolicy.duration(
            afterFailedAttemptCount: 4
        ) == nil)
        #expect(WalletPasscodeLockoutPolicy.duration(
            afterFailedAttemptCount: 5
        ) == TimeInterval(5))
        #expect(WalletPasscodeLockoutPolicy.duration(
            afterFailedAttemptCount: 6
        ) == TimeInterval(30))
        #expect(WalletPasscodeLockoutPolicy.duration(
            afterFailedAttemptCount: 7
        ) == TimeInterval(5 * 60))
        #expect(WalletPasscodeLockoutPolicy.duration(
            afterFailedAttemptCount: 8
        ) == TimeInterval(30 * 60))
        #expect(WalletPasscodeLockoutPolicy.duration(
            afterFailedAttemptCount: 9
        ) == TimeInterval(60 * 60))
        #expect(WalletPasscodeLockoutPolicy.duration(
            afterFailedAttemptCount: 10
        ) == TimeInterval(6 * 60 * 60))
        #expect(WalletPasscodeLockoutPolicy.duration(
            afterFailedAttemptCount: 100
        ) == TimeInterval(6 * 60 * 60))
    }

    @Test
    func lockoutCountdownUsesTheAbsoluteDeadline() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let deadline = start.addingTimeInterval(60 * 60)

        #expect(PasscodeLockoutCountdownModel.remainingSeconds(
            until: deadline,
            at: start.addingTimeInterval(40 * 60)
        ) == 20 * 60)
        #expect(PasscodeLockoutCountdownModel.remainingSeconds(
            until: deadline,
            at: deadline.addingTimeInterval(-0.1)
        ) == 1)
        #expect(PasscodeLockoutCountdownModel.remainingSeconds(
            until: deadline,
            at: deadline
        ) == nil)
    }

    @Test
    func lockoutDurationUsesSecondsMinutesAndHours() {
        #expect(
            PasscodeLockoutMessageFormatter.components(for: 59)
                == .seconds(59)
        )
        #expect(
            PasscodeLockoutMessageFormatter.components(for: 60)
                == .minutesSeconds(minutes: 1, seconds: 0)
        )
        #expect(
            PasscodeLockoutMessageFormatter.components(for: 1_797)
                == .minutesSeconds(minutes: 29, seconds: 57)
        )
        #expect(
            PasscodeLockoutMessageFormatter.components(for: 3_599)
                == .minutesSeconds(minutes: 59, seconds: 59)
        )
        #expect(
            PasscodeLockoutMessageFormatter.components(for: 3_600)
                == .hoursMinutes(hours: 1, minutes: 0)
        )
        #expect(
            PasscodeLockoutMessageFormatter.components(for: 7_199)
                == .hoursMinutes(hours: 1, minutes: 59)
        )
        #expect(
            PasscodeLockoutMessageFormatter.components(for: 21_600)
                == .hoursMinutes(hours: 6, minutes: 0)
        )
    }

    @Test
    func authenticationPersistsEveryEscalatedDeadline() async throws {
        let database = try WalletDatabase.temporary()
        try await database.enableAppLock(passcode: "123456")
        let reference = try #require(
            await database.pool.read { database in
                try DBProfileSecurityRecord.fetchOne(
                    database,
                    key: WalletDatabase.defaultProfileID
                )?.passcodeKeychainReference
            }
        )
        defer {
            try? WalletSecretVault.shared.deletePasscodeCredential(
                reference: reference
            )
        }

        let schedule: [(attempt: Int, seconds: TimeInterval)] = [
            (5, 5),
            (6, 30),
            (7, 5 * 60),
            (8, 30 * 60),
            (9, 60 * 60),
            (10, 6 * 60 * 60),
            (11, 6 * 60 * 60)
        ]

        for item in schedule {
            try await database.pool.write { database in
                guard var security = try DBProfileSecurityRecord.fetchOne(
                    database,
                    key: WalletDatabase.defaultProfileID
                ) else {
                    throw WalletCreationPersistenceError.missingSecret
                }
                security.failedAttemptCount = item.attempt - 1
                security.lockedUntil = nil
                try security.update(database)
            }

            let startedAt = Date()
            let result = try await database.authenticatePasscode("000000")
            guard case let .locked(until) = result else {
                Issue.record("Expected attempt \(item.attempt) to lock.")
                continue
            }
            let actualDuration = until.timeIntervalSince(startedAt)
            #expect(actualDuration >= item.seconds - 0.25)
            #expect(actualDuration <= item.seconds + 1)
        }
    }

    @Test
    func storedDeadlineSurvivesDatabaseReopenAndElapsedTime() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let deadline = start.addingTimeInterval(60 * 60)
        do {
            let database = try WalletDatabase.applicationDatabase(
                at: directory
            )
            try await database.pool.write { database in
                try DBProfileSecurityRecord(
                    profileID: WalletDatabase.defaultProfileID,
                    passcodeKeychainReference: "persisted-lockout-test",
                    failedAttemptCount: 9,
                    lockedUntil: deadline.timeIntervalSince1970,
                    updatedAt: start.timeIntervalSince1970
                ).insert(database)
            }
        }

        let reopened = try WalletDatabase.applicationDatabase(at: directory)
        let afterFortyMinutes = start.addingTimeInterval(40 * 60)
        let restoredDeadline = try await reopened
            .activePasscodeLockoutDeadline(at: afterFortyMinutes)

        #expect(restoredDeadline == deadline)
        #expect(PasscodeLockoutCountdownModel.remainingSeconds(
            until: try #require(restoredDeadline),
            at: afterFortyMinutes
        ) == 20 * 60)
        #expect(try await reopened.activePasscodeLockoutDeadline(
            at: deadline
        ) == nil)
    }
}
