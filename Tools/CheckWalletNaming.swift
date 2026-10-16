import Foundation
import OathDatabase
import OathCloudBackup

/// Production vault/session/storage and bundled translations, synthetic keys
/// and the existing no-network derivation adapter. No app/device is launched.
@main struct CheckWalletNaming {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        // Foundation adds bidi isolation around format arguments in Arabic.
        // Compare visible text while allowing those native layout controls.
        func readable(_ value: String) -> String {
            String(String.UnicodeScalarView(value.unicodeScalars.filter { !(0x2066...0x2069).contains($0.value) }))
        }
        let bundle = Bundle(path: ProcessInfo.processInfo.environment["OATH_TEST_NAMING_BUNDLE"]!)!
        let en = OathLocalizer(.english, bundle: bundle), ar = OathLocalizer(.arabic, bundle: bundle)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oath-names-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
        let pin: [UInt8] = [2, 9, 4, 8, 1, 6]
        try await vault.create(digits: pin, importing: nil)
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup()
        let firstID = session.displayedProfile!.id.uuidString
        check(session.walletName(session.portfolio?.wallet, strings: en) == "Main Wallet", "First created name")
        check(session.walletName(session.portfolio?.wallet, strings: ar) == "المحفظة الرئيسية", "Arabic main name")
        try await session.customizeWallet(firstID, name: "Main Wallet", colorHex: nil, keepDefaultName: true)
        session.finishInitialCustomization()
        for index in 1...2 {
            _ = try await session.addWallet(requestID: UUID())
            check(session.walletName(session.portfolio?.wallet, strings: en) == "Main Wallet \(index)", "Created sequence")
        }
        for index in 0...2 {
            _ = try await session.addWallet(requestID: UUID(), importing: .init(phrase: "synthetic naming fixture \(index)", language: "english"))
            let suffix = index == 0 ? "" : " \(index)"
            check(session.walletName(session.portfolio?.wallet, strings: en) == "Imported Wallet" + suffix, "Imported sequence")
            check(readable(session.walletName(session.portfolio?.wallet, strings: ar)) == "المحفظة المستوردة" + (index == 0 ? "" : " " + ar.number(index)), "Arabic imported sequence")
        }
        for index in 0...1 {
            _ = try await session.addWallet(requestID: UUID(), privateKey: .init(bytes: Data(repeating: UInt8(index + 1), count: 32), networks: [.ethereum, .base]))
            check(session.walletName(session.portfolio?.wallet, strings: en) == "Ethereum Wallet" + (index == 0 ? "" : " \(index)"), "Private key chain sequence")
            check(readable(session.walletName(session.portfolio?.wallet, strings: ar)) == "محفظة Ethereum" + (index == 0 ? "" : " " + ar.number(index)), "Chain remains English in Arabic")
        }
        for chain in OathImportChain.allCases {
            var row = WalletRecord(id: "fixture", name: "", kind: "privateKey", vaultReference: "fixture", createdAt: 1, nameGroup: "network:" + chain.id)
            check(session.walletName(row, strings: en) == chain.name + " Wallet", "Every chain name is unchanged")
            row.nameIndex = 1
            check(readable(session.walletName(row, strings: ar)) == "محفظة " + chain.name + " " + ar.number(1), "Every Arabic chain name is unchanged")
        }
        for index in 0...2 {
            let key = BackupWallet.ImportedPrivateKey(bytes: Data(repeating: UInt8(index + 20), count: 32), networks: ["ethereum"])
            let backup = BackupWallet(id: UUID(), name: "Old backup label", mnemonic: "", language: "", createdAt: .now,
                accounts: [.init(network: "ethereum", derivationPath: "imported", index: 0)], privateKey: key)
            try await session.restoreWallet(OathRestoredWallet(backup: backup))
            check(session.walletName(session.portfolio?.wallet, strings: en) == "Restored Wallet" + (index == 0 ? "" : " \(index)"), "Restore takes precedence over private-key origin")
            check(readable(session.walletName(session.portfolio?.wallet, strings: ar)) == "المحفظة المستعادة" + (index == 0 ? "" : " " + ar.number(index)), "Arabic restored sequence")
        }
        try await session.selectWallet(UUID(uuidString: firstID)!)
        check(session.walletName(session.portfolio?.wallet, strings: ar) == "المحفظة الرئيسية", "Customization did not freeze the default in English")
        await session.lock()
        await session.unlock(pin)
        check(session.walletName(session.portfolio?.wallet, strings: en) == "Main Wallet", "Names survive lock and unlock")
        checks += try await CheckMultiWallet.checkCloudRestore()
        print("Passed \(checks) wallet-naming and local restore checks. No simulator, device, live iCloud, or network was used.")
    }
}
