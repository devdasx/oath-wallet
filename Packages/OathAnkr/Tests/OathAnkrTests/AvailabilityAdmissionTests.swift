import Foundation
import XCTest
@testable import OathDiagnostics
@testable import OathAnkr

final class AvailabilityAdmissionTests: XCTestCase {
    func testRPCRateLimitWrappersAgreeAtAdmissionAndAfterSerialization() {
        let errors: [any Error] = [AnkrError.rpc(429), SolanaError.rpc(429), TonError.rpc(429),
            TronError.rpc(429), StellarError.rpc(429), NearError.rpc(429), EVMSendError.rpc(429),
            SolanaSendError.rpc(429), TonSendError.rpc(429), StellarSendError.rpc(429),
            NearSendError.rpc(429), ArcSendError.rpc(429)]
        for error in errors {
            XCTAssertTrue(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(error, component:"provider", severity:"error",context:[:],runtimeReport:nil),String(reflecting:type(of:error)))
            let event = DiagnosticEvent(error:error,component:"provider",operation:"rpc",sessionID:UUID())
            XCTAssertTrue(DiagnosticUploadPolicy.excludes(event),String(reflecting:type(of:error)))
        }
    }
    func testTypedAdmissionAgreesWithPersistedPolicyAndPreservesRealFailures() {
        let excluded: [any Error] = [AnkrError.transport, SolanaError.transport, AptosError.transport,
            TonError.transport, TronError.transport, StellarError.transport, XrplError.transport,
            NearError.transport, SuiError.transport, ThorchainError.transport, EVMSendError.transport,
            SolanaSendError.transport, AptosSendError.transport, TonSendError.transport, TronSendError.transport,
            StellarSendError.transport, XrplSendError.transport, NearSendError.transport, SuiSendError.transport,
            ThorchainSendError.transport, ArcSendError.transport, TokenDiscoveryError.unavailable,
            SuiError.checkpointUnavailable, StellarError.indexUnavailable, SolanaError.rpc(-32019),
            AnkrError.http(429), AnkrError.http(503), ThorchainError.rateLimited, SuiError.resourceExhausted,
            XrplError.rpc("tooBusy"), XrplSendError.rpc("noNetwork"), AnkrError.rpc(-32005)]
        let retained: [any Error] = [AnkrError.invalidResponse, AnkrError.wrongAccount, AnkrError.wrongChain,
            StellarError.incompleteHistory, SuiError.graphql, SolanaError.rpc(-32020), SolanaSendError.rpc(-32019),
            AnkrError.http(401), AnkrError.http(403), AnkrError.rpc(-32000), SuiError.wrongOwner,
            ThorchainError.malformed, ThorchainError.staleHeight, TokenDiscoveryError.malformed,
            XrplError.rpc("invalidParams"), EVMSendError.signing, TronSendError.execution]
        for (errors, expected) in [(excluded, true), (retained, false)] {
            for error in errors {
                let fresh = DiagnosticAvailabilityPolicy.excludesBeforeAdmission(error, component: "provider", severity: "error", context: [:], runtimeReport: nil)
                let event = DiagnosticEvent(error: error, component: "provider", operation: "policy_fixture", sessionID: UUID())
                XCTAssertEqual(fresh, expected, String(describing: error))
                XCTAssertEqual(DiagnosticUploadPolicy.excludes(event), expected, String(describing: error))
                // A fatal report is never removed solely because its top-level
                // type happens to be a normally excluded availability error.
                XCTAssertFalse(DiagnosticAvailabilityPolicy.excludesBeforeAdmission(error, component: "provider", severity: "fatal", context: [:], runtimeReport: nil))
            }
        }
    }
}
