import Foundation
import Security
import Testing
@testable import Aperture

@MainActor
struct WalletLaunchPasscodeCredentialResolverTests {
    @Test
    func waitsForActiveProtectedStateBeforeReadingCredential()
        async throws
    {
        var protectionChecks = 0
        var readinessReads = 0
        let resolver = makeResolver(
            protectionCheckLimit: 4,
            readinessAttemptLimit: 2,
            protectionState: {
                protectionChecks += 1
                return .init(
                    isApplicationActive: protectionChecks >= 3,
                    isProtectedDataAvailable: protectionChecks >= 2
                )
            },
            readiness: {
                readinessReads += 1
                return .available
            }
        )

        let result = try await resolver.resolve()

        #expect(result == .available)
        #expect(protectionChecks == 3)
        #expect(readinessReads == 1)
    }

    @Test
    func retriesTransientColdLaunchFailuresUntilCredentialIsAvailable()
        async throws
    {
        var results: [WalletPasscodeCredentialReadiness] = [
            .unavailable(
                .keychainTemporarilyUnavailable(
                    errSecInteractionNotAllowed
                )
            ),
            .unavailable(
                .keychainTemporarilyUnavailable(errSecNotAvailable)
            ),
            .available
        ]
        var readinessReads = 0
        let resolver = makeResolver(
            protectionCheckLimit: 1,
            readinessAttemptLimit: 4,
            protectionState: {
                .init(
                    isApplicationActive: true,
                    isProtectedDataAvailable: true
                )
            },
            readiness: {
                readinessReads += 1
                return results.removeFirst()
            }
        )

        let result = try await resolver.resolve()

        #expect(result == .available)
        #expect(readinessReads == 3)
    }

    @Test
    func productionPolicyWaitsPastFormerProtectedDataDeadline()
        async throws
    {
        var protectionChecks = 0
        var readinessReads = 0
        let resolver = makeResolver(
            protectionCheckLimit: nil,
            readinessAttemptLimit: nil,
            protectionState: {
                protectionChecks += 1
                return .init(
                    isApplicationActive: protectionChecks >= 75,
                    isProtectedDataAvailable: protectionChecks >= 75
                )
            },
            readiness: {
                readinessReads += 1
                return .available
            }
        )

        let result = try await resolver.resolve()

        #expect(result == .available)
        #expect(protectionChecks == 75)
        #expect(readinessReads == 1)
    }

    @Test
    func productionPolicyWaitsPastFormerKeychainRetryDeadline()
        async throws
    {
        var readinessReads = 0
        let resolver = makeResolver(
            protectionCheckLimit: nil,
            readinessAttemptLimit: nil,
            protectionState: {
                .init(
                    isApplicationActive: true,
                    isProtectedDataAvailable: true
                )
            },
            readiness: {
                readinessReads += 1
                if readinessReads <= 12 {
                    return .unavailable(
                        .keychainTemporarilyUnavailable(
                            errSecInteractionNotAllowed
                        )
                    )
                }
                return .available
            }
        )

        let result = try await resolver.resolve()

        #expect(result == .available)
        #expect(readinessReads == 13)
    }

    @Test
    func missingCredentialDoesNotWasteTimeOnDeterministicRetries()
        async throws
    {
        var readinessReads = 0
        let resolver = makeResolver(
            protectionCheckLimit: 1,
            readinessAttemptLimit: 5,
            protectionState: {
                .init(
                    isApplicationActive: true,
                    isProtectedDataAvailable: true
                )
            },
            readiness: {
                readinessReads += 1
                return .unavailable(.credentialNotFound)
            }
        )

        let result = try await resolver.resolve()

        #expect(result == .unavailable(.credentialNotFound))
        #expect(readinessReads == 1)
    }

    @Test
    func signingEntitlementFailureIsNeverClassifiedAsTransient()
        async throws
    {
        var readinessReads = 0
        let resolver = makeResolver(
            protectionCheckLimit: 1,
            readinessAttemptLimit: 5,
            protectionState: {
                .init(
                    isApplicationActive: true,
                    isProtectedDataAvailable: true
                )
            },
            readiness: {
                readinessReads += 1
                return .unavailable(
                    .keychainAccessFailed(errSecMissingEntitlement)
                )
            }
        )

        let result = try await resolver.resolve()

        #expect(
            result == .unavailable(
                .keychainAccessFailed(errSecMissingEntitlement)
            )
        )
        #expect(readinessReads == 1)
    }

    @Test
    func missingSecurityRecordRemainsFailClosedWithoutRetry()
        async throws
    {
        var readinessReads = 0
        let resolver = makeResolver(
            protectionCheckLimit: 1,
            readinessAttemptLimit: 5,
            protectionState: {
                .init(
                    isApplicationActive: true,
                    isProtectedDataAvailable: true
                )
            },
            readiness: {
                readinessReads += 1
                return .unavailable(.missingSecurityRecord)
            }
        )

        let result = try await resolver.resolve()

        #expect(result == .unavailable(.missingSecurityRecord))
        #expect(readinessReads == 1)
    }

    @Test
    func unavailableProtectedDataNeverReadsCredentialOrUnlocks()
        async throws
    {
        var readinessReads = 0
        let resolver = makeResolver(
            protectionCheckLimit: 3,
            readinessAttemptLimit: 3,
            protectionState: {
                .init(
                    isApplicationActive: true,
                    isProtectedDataAvailable: false
                )
            },
            readiness: {
                readinessReads += 1
                return .protectionDisabled
            }
        )

        let result = try await resolver.resolve()

        #expect(
            result == .unavailable(
                .keychainTemporarilyUnavailable(
                    errSecInteractionNotAllowed
                )
            )
        )
        #expect(readinessReads == 0)
    }

    @Test
    func databaseConfirmedDisabledProtectionPassesThrough()
        async throws
    {
        let resolver = makeResolver(
            protectionCheckLimit: 1,
            readinessAttemptLimit: 5,
            protectionState: {
                .init(
                    isApplicationActive: true,
                    isProtectedDataAvailable: true
                )
            },
            readiness: {
                .protectionDisabled
            }
        )

        let result = try await resolver.resolve()

        #expect(result == .protectionDisabled)
    }

    private func makeResolver(
        protectionCheckLimit: Int?,
        readinessAttemptLimit: Int?,
        protectionState:
            @escaping WalletLaunchPasscodeCredentialResolver
                .ProtectionStateProvider,
        readiness:
            @escaping WalletLaunchPasscodeCredentialResolver
                .ReadinessProvider
    ) -> WalletLaunchPasscodeCredentialResolver {
        WalletLaunchPasscodeCredentialResolver(
            policy: .init(
                protectionCheckLimit: protectionCheckLimit,
                readinessAttemptLimit: readinessAttemptLimit,
                protectionCheckDelayNanoseconds: 1,
                readinessRetryDelayNanoseconds: 1
            ),
            protectionState: protectionState,
            readiness: readiness,
            pause: { _ in }
        )
    }
}

struct WalletPasscodeCredentialEncodingTests {
    @Test
    func currentEncodingIsUnversionedAndReadsExistingCredentialData()
        throws
    {
        let credential = try WalletPasscodeCredential.make(
            passcode: "123456"
        )
        let currentData = try JSONEncoder().encode(credential)
        let currentObject = try #require(
            JSONSerialization.jsonObject(with: currentData)
                as? [String: Any]
        )
        #expect(currentObject["version"] == nil)

        var existingObject = currentObject
        existingObject["version"] = 1
        let existingData = try JSONSerialization.data(
            withJSONObject: existingObject,
            options: [.sortedKeys]
        )
        let decoded = try WalletPasscodeCredential.decodeStoredData(
            existingData
        )

        #expect(decoded.matches(passcode: "123456"))
        #expect(!decoded.matches(passcode: "654321"))
    }
}
