import Foundation

private actor DisclosureReader: OathPrivateKeyReading {
    static let account = OathPrivateKeyAccount(id: "fixture-account", chain: .ethereum,
        address: "synthetic-public-address", path: "m/44'/60'/0'/0/0")
    private(set) var reads = 0
    func privateKeyAccounts(walletID: String) async throws -> [OathPrivateKeyAccount] { [Self.account] }
    func privateKey(walletID: String, accountID: String, digits: [UInt8]) async throws -> OathPrivateKeyExport {
        try await privateKeyWithBiometrics(walletID: walletID, accountID: accountID, reason: "fixture")
    }
    func privateKeyWithBiometrics(walletID: String, accountID: String, reason: String) async throws -> OathPrivateKeyExport {
        reads += 1
        return .init(value: "SYNTHETIC-NOT-A-PRIVATE-KEY", format: "fixture")
    }

}

@main struct CheckPrivateKeyDisclosure {
    struct FixtureFailure: Error {}
    @MainActor static func main() async throws {
        var passed = 0, failed = 0
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1; print("PASS: \(name)") }
            else { failed += 1; print("FAIL: \(name)") }
        }
        func settle(_ model: OathPrivateKeyModel) async throws {
            for _ in 0..<1000 where model.busy { try await Task.sleep(for: .milliseconds(2)) }
            if model.busy { throw FixtureFailure() }
        }
        let reader = DisclosureReader()
        let model = OathPrivateKeyModel(walletID: "synthetic-wallet", reader: reader)
        await model.load()
        model.select(DisclosureReader.account, reason: "Synthetic fixture")
        try await settle(model)
        check(model.phase == .warning && model.key == nil, "authorization stops at warning")
        model.acknowledge()
        check(model.phase == .revealed && model.key != nil, "acknowledged value is available while active")
        model.returnToWarning()
        check(model.phase == .warning && model.key == nil, "native back removes displayed value")
        model.acknowledge()
        check(model.phase == .revealed && model.key != nil, "active warning may re-reveal same authorization")

        model.cancelAuthentication()
        check(model.key == nil && model.phase == .chains && model.selected == nil,
              "lock or background clears revealed value and selection")
        model.returnToWarning(); model.acknowledge()
        check(model.key == nil && model.phase == .chains,
              "old acknowledgement cannot reveal after cancellation")
        model.cancelAuthentication()
        check(model.key == nil && !model.accounts.isEmpty, "repeated cleanup preserves only public accounts")
        // Reset explicitly so all controls execute even on the vulnerable source.
        model.returnToChains()
        let previousReads = await reader.reads
        model.select(DisclosureReader.account, reason: "Fresh authorization")
        try await settle(model)
        check(await reader.reads == previousReads + 1 && model.phase == .warning && model.key == nil,
              "reopening requires another authorization and warning")
        model.cancelAuthentication(); model.acknowledge()
        check(model.key == nil && model.phase == .chains, "unacknowledged value is discarded")

        model.select(DisclosureReader.account, reason: "New request after cancellation")
        try await settle(model)
        model.acknowledge()
        check(model.key?.value == "SYNTHETIC-NOT-A-PRIVATE-KEY", "new authorization keeps its own value")
        model.cancelAuthentication()
        check(model.key == nil && model.phase == .chains, "fresh disclosure also clears on background")
        print("Private-key disclosure checks: \(passed) passed, \(failed) failed; synthetic reader, production model; no UIKit or OS authentication.")
        fflush(nil)
        if failed != 0 { throw FixtureFailure() }
    }
}
