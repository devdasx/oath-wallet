import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct LocalPrivateScanningSecurityTests {
    @Test
    func scanningFailsClosedBeforeAnyNetworkOrKeySerialization() async throws {
        let draft = try WalletCoreService.generateEVMWallet()
        let credential = try WalletRecoveryCredential(mnemonic: draft.mnemonic, passphrase: "")
        let material = try BitcoinSilentPaymentKeyMaterial.derive(
            walletID: "ephemeral-test-wallet", credential: credential
        )
        let client = BitcoinSilentPaymentScanClient()
        #expect(!BitcoinSilentPaymentScanClient.isAvailable)
        await #expect(throws: BitcoinSilentPaymentScanError.localScanningUnavailable) {
            _ = try await client.scan(keyMaterial: material, startHeight: 840000)
        }
        await #expect(throws: BitcoinSilentPaymentScanError.localScanningUnavailable) {
            _ = try await client.liveUpdates(keyMaterial: material, startHeight: 840000)
        }
        await #expect(throws: BitcoinSilentPaymentScanError.localScanningUnavailable) {
            _ = try await client.tipHeight()
        }
    }
}
