import Security
import Testing
@testable import Aperture

#if DEBUG
struct AnkrConfigurationConcurrencyTests {
    @Test
    func duplicateConcurrentKeychainInsertRetriesAsUpdate() {
        #expect(
            AnkrDevelopmentCredentialInsertResolution(
                status: errSecDuplicateItem
            ) == .retryUpdate
        )
    }

    @Test
    func successfulKeychainInsertNeedsNoSecondWrite() {
        #expect(
            AnkrDevelopmentCredentialInsertResolution(
                status: errSecSuccess
            ) == .complete
        )
    }

    @Test
    func unexpectedKeychainFailureRemainsActionable() {
        let status = errSecInteractionNotAllowed

        #expect(
            AnkrDevelopmentCredentialInsertResolution(
                status: status
            ) == .failure(status)
        )
    }
}
#endif
