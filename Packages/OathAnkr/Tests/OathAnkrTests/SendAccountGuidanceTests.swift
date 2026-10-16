import XCTest
@testable import OathAnkr

final class SendAccountGuidanceTests: XCTestCase {
    func testNativeMinimumUsesLiveValueAndEditsAmount() throws {
        for (error, topic, minimum): (Error, SendAccountGuidance.Topic, UInt64) in [
            (XrplSendError.recipientMinimum(2_000_000), .xrpActivation, 2_000_000),
            (StellarSendError.recipientMinimum(15_000_000), .stellarActivation, 15_000_000),
            (SolanaSendError.recipientMinimum(890_880), .solanaActivation, 890_880)
        ] {
            let advice = try XCTUnwrap(SendAccountGuidance.failure(error, native: true))
            XCTAssertEqual(advice.topic, topic); XCTAssertEqual(advice.minimumAtomic, minimum)
            XCTAssertEqual(advice.action, .editAmount); XCTAssertTrue(advice.isBlocking)
        }
    }
    func testTokenActivationNeverSuggestsIncreasingTokenAmount() throws {
        for error: Error in [XrplSendError.recipientUnfunded, StellarSendError.recipientUnfunded, StellarSendError.trustline] {
            let advice = try XCTUnwrap(SendAccountGuidance.failure(error, native: false))
            XCTAssertEqual(advice.action, .editRecipient); XCTAssertNil(advice.minimumAtomic)
        }
        XCTAssertEqual(SendAccountGuidance.failure(NearSendError.recipientMissing, native: false, implicitNearRecipient: true)?.topic, .nearTokenActivation)
        XCTAssertEqual(SendAccountGuidance.failure(NearSendError.recipientMissing, native: true)?.topic, .nearAccount)
    }
    func testSenderFeeAndReserveRecoveryDependsOnAsset() {
        for error: Error in [XrplSendError.reserve, StellarSendError.reserve, TronSendError.activationFunds(1_100_000), TronSendError.insufficientFunds, SolanaSendError.storageBalance] {
            XCTAssertEqual(SendAccountGuidance.failure(error, native: true)?.action, .editAmount)
            XCTAssertEqual(SendAccountGuidance.failure(error, native: false)?.action, .refresh)
        }
        XCTAssertEqual(SendAccountGuidance.failure(SolanaSendError.accountRent, native: false)?.topic, .solanaRent)
        XCTAssertEqual(SendAccountGuidance.failure(TronSendError.senderInactive, native: true)?.topic, .tronSenderActivation)
    }
    func testProviderErrorsAndOtherChainsDoNotInventActivationRequirements() {
        for error: Error in [CancellationError(), XrplSendError.transport, StellarSendError.http(404),
                             TronSendError.simulation, SolanaSendError.simulationFailed, NearSendError.rpc(-32000),
                             EVMSendError.insufficientFunds, AptosSendError.insufficientFunds, SuiSendError.insufficientGas, TonSendError.simulationFailed] {
            XCTAssertNil(SendAccountGuidance.failure(error, native: true))
        }
    }
}
