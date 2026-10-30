import XCTest
@testable import OathDatabase

final class WalletSecurityNoticeQueueTests: XCTestCase {
    private let wallet = UUID()

    func testBothFindingsShowInOrderAfterNativeDismissal() throws {
        var queue = WalletSecurityNoticeQueue()
        let first = try XCTUnwrap(queue.next(walletID: wallet, homeAvailable: true,
                                            multisigPending: true, stablecoinPending: true))
        XCTAssertEqual(first.kind, .multisig)
        XCTAssertTrue(queue.begin(first))
        // Got it has saved only the multisig acknowledgement; sheet binding
        // is already nil, but the native dismiss animation has not finished.
        XCTAssertNil(queue.next(walletID: wallet, homeAvailable: true,
                                multisigPending: false, stablecoinPending: true))
        queue.didDismiss()
        let second = try XCTUnwrap(queue.next(walletID: wallet, homeAvailable: true,
                                             multisigPending: false, stablecoinPending: true))
        XCTAssertEqual(second.kind, .stablecoin)
        XCTAssertEqual(second.walletID, wallet)
        XCTAssertTrue(queue.begin(second))
        queue.didDismiss()
        XCTAssertNil(queue.next(walletID: wallet, homeAvailable: true,
                                multisigPending: false, stablecoinPending: false))
    }

    func testEitherDetectorCanFinishFirstWithoutOverwritingItsSheet() throws {
        for multisigFirst in [true, false] {
            var queue = WalletSecurityNoticeQueue()
            let first = try XCTUnwrap(queue.next(walletID: wallet, homeAvailable: true,
                multisigPending: multisigFirst, stablecoinPending: !multisigFirst))
            XCTAssertTrue(queue.begin(first))
            // The other detector finishes while this sheet is open.
            XCTAssertNil(queue.next(walletID: wallet, homeAvailable: true,
                                    multisigPending: true, stablecoinPending: true))
            XCTAssertFalse(queue.begin(first), "Repeated state updates cannot reserve another presentation")
            // First acknowledgement saved, but still dismissing.
            XCTAssertNil(queue.next(walletID: wallet, homeAvailable: true,
                multisigPending: !multisigFirst, stablecoinPending: multisigFirst))
            queue.didDismiss()
            let second = try XCTUnwrap(queue.next(walletID: wallet, homeAvailable: true,
                multisigPending: !multisigFirst, stablecoinPending: multisigFirst))
            XCTAssertNotEqual(second.kind, first.kind)
            XCTAssertEqual(second.walletID, wallet)
        }
    }

    func testLateFindingAfterFirstDismissalStillAppears() throws {
        var queue = WalletSecurityNoticeQueue()
        let first = try XCTUnwrap(queue.next(walletID: wallet, homeAvailable: true,
                                            multisigPending: true, stablecoinPending: false))
        queue.begin(first)
        queue.didDismiss()
        XCTAssertNil(queue.next(walletID: wallet, homeAvailable: true,
                                multisigPending: false, stablecoinPending: false))
        XCTAssertEqual(queue.next(walletID: wallet, homeAvailable: true,
                                  multisigPending: false, stablecoinPending: true)?.kind, .stablecoin)
    }

    func testWalletSwitchWaitsForOldDismissalAndUsesOnlyCurrentWallet() throws {
        var queue = WalletSecurityNoticeQueue()
        let first = try XCTUnwrap(queue.next(walletID: wallet, homeAvailable: true,
                                            multisigPending: false, stablecoinPending: true))
        queue.begin(first)
        let other = UUID()
        XCTAssertNil(queue.next(walletID: other, homeAvailable: true,
                                multisigPending: true, stablecoinPending: true))
        queue.didDismiss()
        XCTAssertNil(queue.next(walletID: other, homeAvailable: true,
                                multisigPending: false, stablecoinPending: false))
        let current = try XCTUnwrap(queue.next(walletID: other, homeAvailable: true,
                                              multisigPending: true, stablecoinPending: true))
        XCTAssertEqual(current.walletID, other)
        XCTAssertEqual(current.kind, .multisig)
    }

    func testLockOrNavigationDefersWithoutAcknowledgingOrLosingPendingWarning() throws {
        var queue = WalletSecurityNoticeQueue()
        let first = try XCTUnwrap(queue.next(walletID: wallet, homeAvailable: true,
                                            multisigPending: true, stablecoinPending: true))
        queue.begin(first)
        queue.didDismiss() // Lock dismissed the sheet without Got it.
        XCTAssertNil(queue.next(walletID: wallet, homeAvailable: false,
                                multisigPending: true, stablecoinPending: true))
        XCTAssertEqual(queue.next(walletID: wallet, homeAvailable: true,
                                  multisigPending: true, stablecoinPending: true), first)
    }

    func testMissingWalletAndNoPendingFindingsNeverPresent() {
        let queue = WalletSecurityNoticeQueue()
        XCTAssertNil(queue.next(walletID: nil, homeAvailable: true,
                                multisigPending: true, stablecoinPending: true))
        XCTAssertNil(queue.next(walletID: wallet, homeAvailable: true,
                                multisigPending: false, stablecoinPending: false))
    }
}
