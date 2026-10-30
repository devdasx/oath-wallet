import Foundation
import XCTest
@testable import OathDiagnostics
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

final class DiagnosticCancellationTests: XCTestCase {
    func testCocoaUserCancellationFromNativeCallbacksIsExpected() {
        XCTAssertTrue(OathDiagnostics.isExpectedCancellation(CocoaError(.userCancelled)))
        XCTAssertTrue(OathDiagnostics.isExpectedCancellation(NSError(domain: NSCocoaErrorDomain, code: 3072)))
    }

    func testCocoaFailuresAndWrappedCancellationRemainReportable() {
        for code: CocoaError.Code in [.fileReadNoPermission, .fileWriteNoPermission, .fileWriteOutOfSpace,
                                     .coderReadCorrupt, .featureUnsupported] {
            XCTAssertFalse(OathDiagnostics.isExpectedCancellation(CocoaError(code)), "\(code)")
        }
        XCTAssertFalse(OathDiagnostics.isExpectedCancellation(NSError(domain: "Unrelated", code: 3072)))
        let wrapped = NSError(domain: "WalletStorage", code: 1,
            userInfo: [NSUnderlyingErrorKey: CocoaError(.userCancelled)])
        XCTAssertFalse(OathDiagnostics.isExpectedCancellation(wrapped))
    }

    func testExplicitTaskAndNetworkCancellationOnly() {
        XCTAssertTrue(OathDiagnostics.isExpectedCancellation(CancellationError()))
        XCTAssertTrue(OathDiagnostics.isExpectedCancellation(URLError(.cancelled)))
        XCTAssertFalse(OathDiagnostics.isExpectedCancellation(URLError(.timedOut)))
        XCTAssertFalse(OathDiagnostics.isExpectedCancellation(URLError(.networkConnectionLost)))
        XCTAssertFalse(OathDiagnostics.isExpectedCancellation(NSError(domain: "Unrelated", code: -999)))
    }

    #if canImport(LocalAuthentication)
    func testNativeAuthenticationCancellationAndFallbackAreNotFailures() {
        for code: LAError.Code in [.userCancel, .userFallback, .systemCancel, .appCancel] {
            // NSError bridging matches the error supplied by the native callback.
            let error = NSError(domain: LAError.errorDomain, code: code.rawValue)
            XCTAssertTrue(OathDiagnostics.isExpectedCancellation(error), "\(code)")
        }
    }

    func testRealAuthenticationErrorsAndUnrelatedDomainsStayReportable() {
        for code: LAError.Code in [.authenticationFailed, .invalidContext, .notInteractive,
                                   .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled] {
            XCTAssertFalse(OathDiagnostics.isExpectedCancellation(LAError(code)), "\(code)")
        }
        XCTAssertFalse(OathDiagnostics.isExpectedCancellation(NSError(domain: "Unrelated", code: LAError.userCancel.rawValue)))
        let failedRequest = NSError(domain: "WalletStorage", code: 1,
            userInfo: [NSUnderlyingErrorKey: LAError(.userCancel)])
        XCTAssertFalse(OathDiagnostics.isExpectedCancellation(failedRequest), "Do not hide a real outer failure because its underlying error was cancelled")
    }
    #endif
}
