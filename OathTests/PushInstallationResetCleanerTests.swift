import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct PushInstallationResetCleanerTests {
    @Test
    func missingIdentityAndTombstonesRequireNoCleanup() throws {
        let vault = ResetCleanerVaultFixture(
            readiness: .value(false)
        )
        let cleaner = PushInstallationResetCleaner(
            vault: vault,
            clientFactory: {
                ResetCleanerClientFixture()
            }
        )

        #expect(try cleaner.preflightRequiresCleanup() == false)
    }

    @Test
    func unreadableIdentityIsNotTreatedAsMissing() {
        let vault = ResetCleanerVaultFixture(
            readiness: .failure(.unreadable)
        )
        let cleaner = PushInstallationResetCleaner(
            vault: vault,
            clientFactory: {
                ResetCleanerClientFixture()
            }
        )

        do {
            _ = try cleaner.preflightRequiresCleanup()
            Issue.record("Unreadable push state was treated as absent.")
        } catch ResetCleanerTestError.unreadable {
            // Expected: reset must stop before destructive database work.
        } catch {
            Issue.record("Unexpected preflight error: \(type(of: error))")
        }
    }

    @Test
    func serverFailurePreservesTombstoneForSuccessfulRetry()
        async throws
    {
        let vault = ResetCleanerVaultFixture(
            readiness: .value(true),
            hasCurrentIdentity: true
        )
        let failingClient = ResetCleanerClientFixture(
            error: PushNotificationAPIError.transport("injected")
        )
        let firstCleaner = PushInstallationResetCleaner(
            vault: vault,
            clientFactory: { failingClient }
        )

        let first = await firstCleaner.cleanup()
        #expect(first.completedCount == 0)
        #expect(first.pendingCount == 1)
        #expect(vault.hasCurrentIdentity == false)
        #expect(vault.tombstoneCount == 1)
        #expect(vault.didDeleteAllResetState == false)

        let successfulClient = ResetCleanerClientFixture()
        let retryCleaner = PushInstallationResetCleaner(
            vault: vault,
            clientFactory: { successfulClient }
        )
        let retry = await retryCleaner.cleanup()

        #expect(retry.completedCount == 1)
        #expect(retry.pendingCount == 0)
        #expect(vault.tombstoneCount == 0)
        #expect(vault.didDeleteAllResetState)
        #expect(successfulClient.deactivationCount == 1)
    }

    @Test
    func explicitMissingInstallationIsTreatedAsAlreadyDeactivated()
        async
    {
        let vault = ResetCleanerVaultFixture(
            readiness: .value(true),
            tombstones: [ResetCleanerVaultFixture.tombstone]
        )
        let client = ResetCleanerClientFixture(
            error: PushNotificationAPIError.server(
                status: 404,
                code: "installation_not_found"
            )
        )
        let cleaner = PushInstallationResetCleaner(
            vault: vault,
            clientFactory: { client }
        )

        let result = await cleaner.cleanup()
        #expect(result.completedCount == 1)
        #expect(result.pendingCount == 0)
        #expect(vault.tombstoneCount == 0)
        #expect(vault.didDeleteAllResetState)
    }

    @Test
    func rejectedCredentialPreservesServerTombstone() async {
        let vault = ResetCleanerVaultFixture(
            readiness: .value(true),
            tombstones: [ResetCleanerVaultFixture.tombstone]
        )
        let client = ResetCleanerClientFixture(
            error: PushNotificationAPIError.server(
                status: 401,
                code: "installation_authentication_failed"
            )
        )
        let cleaner = PushInstallationResetCleaner(
            vault: vault,
            clientFactory: { client }
        )

        let result = await cleaner.cleanup()
        #expect(result.completedCount == 0)
        #expect(result.pendingCount == 1)
        #expect(vault.tombstoneCount == 1)
        #expect(vault.didDeleteAllResetState == false)
    }

    @Test
    func localVaultDeletionFailureRemainsPending()
        async
    {
        let vault = ResetCleanerVaultFixture(
            readiness: .value(true),
            tombstones: [ResetCleanerVaultFixture.tombstone],
            failDeleteAllResetState: true
        )
        let cleaner = PushInstallationResetCleaner(
            vault: vault,
            clientFactory: {
                ResetCleanerClientFixture()
            }
        )

        let result = await cleaner.cleanup()
        #expect(result.completedCount == 1)
        #expect(result.pendingCount == 1)
        #expect(result.lastErrorCode != nil)
        #expect(vault.didDeleteAllResetState == false)
    }
}

private enum ResetCleanerTestError: Error {
    case unreadable
    case deleteFailed
}

private enum ResetCleanerReadiness {
    case value(Bool)
    case failure(ResetCleanerTestError)
}

private final class ResetCleanerVaultFixture:
    PushInstallationResetVault, @unchecked Sendable
{
    static let tombstone = PushDeactivationTombstone(
        installationID:
            "10000000-0000-4000-8000-000000000001",
        credential: Data(repeating: 0x44, count: 32),
        createdAt: Date(timeIntervalSince1970: 1)
    )

    private let lock = NSLock()
    private let readiness: ResetCleanerReadiness
    private var currentIdentity: Bool
    private var storedTombstones: [PushDeactivationTombstone]
    private let failDeleteAllResetState: Bool
    private var deletedAllResetState = false

    init(
        readiness: ResetCleanerReadiness,
        hasCurrentIdentity: Bool = false,
        tombstones: [PushDeactivationTombstone] = [],
        failDeleteAllResetState: Bool = false
    ) {
        self.readiness = readiness
        currentIdentity = hasCurrentIdentity
        storedTombstones = tombstones
        self.failDeleteAllResetState = failDeleteAllResetState
    }

    var hasCurrentIdentity: Bool {
        lock.withLock { currentIdentity }
    }

    var tombstoneCount: Int {
        lock.withLock { storedTombstones.count }
    }

    var didDeleteAllResetState: Bool {
        lock.withLock { deletedAllResetState }
    }

    func resetCleanupReadiness() throws -> Bool {
        switch readiness {
        case let .value(value):
            value
        case let .failure(error):
            throw error
        }
    }

    func prepareCurrentIdentityForReset() throws {
        lock.withLock {
            guard currentIdentity else { return }
            currentIdentity = false
            storedTombstones.removeAll {
                $0.installationID == Self.tombstone.installationID
            }
            storedTombstones.append(Self.tombstone)
        }
    }

    func deactivationTombstones() throws
        -> [PushDeactivationTombstone]
    {
        lock.withLock { storedTombstones }
    }

    func removeTombstone(installationID: String) throws {
        lock.withLock {
            storedTombstones.removeAll {
                $0.installationID == installationID
            }
        }
    }

    func deleteAllResetState() throws {
        try lock.withLock {
            if failDeleteAllResetState {
                throw ResetCleanerTestError.deleteFailed
            }
            currentIdentity = false
            storedTombstones = []
            deletedAllResetState = true
        }
    }
}

private final class ResetCleanerClientFixture:
    PushInstallationDeactivating, @unchecked Sendable
{
    private let lock = NSLock()
    private let error: Error?
    private var storedDeactivationCount = 0

    init(error: Error? = nil) {
        self.error = error
    }

    var deactivationCount: Int {
        lock.withLock { storedDeactivationCount }
    }

    func deactivate(
        installationID: String,
        credential: Data
    ) async throws {
        lock.withLock {
            storedDeactivationCount += 1
        }
        if let error {
            throw error
        }
    }
}
