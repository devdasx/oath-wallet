import XCTest
@testable import Aperture

final class ICloudBackupDeletionAuthorizationPolicyTests: XCTestCase {
    func testDisabledAppLockDeletesWithoutAuthentication() {
        let settings = WalletSecuritySettings(
            appLockEnabled: false,
            biometricEnabled: false,
            autoLockDuration: .minute1,
            privacyShieldEnabled: false
        )

        XCTAssertEqual(
            ICloudBackupDeletionAuthorizationPolicy.decision(
                settings: settings
            ),
            .deleteWithoutAuthentication
        )
    }

    func testPasscodeEnabledRequiresAuthentication() {
        let settings = WalletSecuritySettings(
            appLockEnabled: true,
            biometricEnabled: false,
            autoLockDuration: .minute1,
            privacyShieldEnabled: false
        )

        XCTAssertEqual(
            ICloudBackupDeletionAuthorizationPolicy.decision(
                settings: settings
            ),
            .authenticate
        )
    }

    func testBiometricsEnabledUsesAuthenticatedRoute() {
        let settings = WalletSecuritySettings(
            appLockEnabled: true,
            biometricEnabled: true,
            autoLockDuration: .minute1,
            privacyShieldEnabled: false
        )

        XCTAssertEqual(
            ICloudBackupDeletionAuthorizationPolicy.decision(
                settings: settings
            ),
            .authenticate
        )
    }
}
