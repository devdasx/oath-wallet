import Foundation
import OathBitcoin
import OathDatabase

/// Exercises production vault authorization, address ownership and browser state.
/// Only mnemonic-to-seed is a deterministic host adapter; curve/WIF code is real.
@main struct CheckHDPrivateKeys {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ reason: String) { precondition(value, reason); checks += 1 }
        func settle(_ model: OathPrivateKeyModel) async throws {
            for _ in 0..<600 where model.busy { try await Task.sleep(for: .milliseconds(5)) }
            check(!model.busy, "Operation must finish")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathHDKeyBrowser-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let vault = OathWalletVault(storage: WalletMemory(), biometricStore: MemoryBiometrics(), database: db)
        let pin: [UInt8] = [4, 1, 7, 9, 2, 6]
        try await vault.create(digits: pin, importing: nil)
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup()
        let walletID = session.displayedProfile!.id.uuidString
        let otherID = try await session.addWallet(requestID: UUID())
        // Browse an inactive wallet, using its own records rather than the
        // currently selected wallet's descriptor or balance snapshot.
        let model = OathPrivateKeyModel(walletID: walletID, reader: vault)
        await model.load()
        for network in UTXONetwork.allCases {
            let chain = model.accounts.first { $0.chain.id == network.rawValue }!
            model.browse(chain)
            await model.loadBranches()
            let expectedTypes = network == .bitcoin || network == .litecoin ? 4 : 1
            check(Set(model.branches.map(\.type)).count == expectedTypes, "Every supported type must appear")
            check(Set(model.branches.map(\.change)) == [0, 1], "HD wallets have receive and change branches")
            for branch in model.branches {
                model.chooseBranch(branch)
                await model.loadAddresses()
                check(model.addresses.count == 20 && !model.hasMoreAddresses, "All generated lookahead addresses must be browsable")
                check(model.addresses.allSatisfy { $0.utxo?.address.branchID == branch.id }, "Receive and change stay separate")
                let leaf = model.addresses.last!
                model.setAddressSearch(.init(query: "Address 19"))
                check(model.addresses.isEmpty && model.hasMoreAddresses, "A new query resets pagination")
                await model.loadAddresses()
                check(model.addresses == [leaf] && !model.hasMoreAddresses, "Search uses the production vault and stored public addresses")
                model.setAddressSearch(.init(query: "missing address"))
                await model.loadAddresses()
                check(model.addresses.isEmpty && model.notice == nil && !model.hasMoreAddresses, "No matches is an ordinary empty result")
                model.setAddressSearch(.init())
                await model.loadAddresses()
                check(model.addresses.count == 20, "Clearing search restores the full branch")
                let key = try await vault.privateKey(walletID: walletID, accountID: leaf.id, digits: pin)
                let decoded = try network.decodeImport(key.value)
                check(key.format == "WIF" && decoded.extended == nil, "Export only the selected leaf")
                let descriptor = try network.singleKey(bytes: decoded.bytes, compressed: decoded.compressed)
                let matching = descriptor.branches.first { $0.type == branch.type }!
                check(try BitcoinKeys.addresses(branch: matching, range: 0..<1)[0].address == leaf.address, "Leaf must own the selected public address")
                do { _ = try await vault.privateKey(walletID: otherID, accountID: leaf.id, digits: pin); preconditionFailure("Cross-wallet address was accepted") }
                catch { check(true, "Cross-wallet address rejected") }
                do { _ = try await vault.privateKey(walletID: walletID, accountID: chain.id + "|utxo|" + branch.id + ":9999", digits: pin); preconditionFailure("Ungenerated address was accepted") }
                catch { check(true, "Unknown address rejected") }
            }
            let leaf = model.addresses[0]
            model.select(leaf, reason: "Public fixture only")
            try await settle(model)
            check(model.phase == .passcode && model.key == nil, "Unavailable biometrics require passcode before export")
            model.submit(pin)
            try await settle(model)
            check(model.phase == .warning && model.key == nil, "Key hidden until acknowledgement")
            model.acknowledge()
            check(model.phase == .revealed && model.key?.format == "WIF", "Authenticated address reveals a WIF")
            model.returnToBrowser()
            check(model.key == nil && model.selected == nil && !model.addresses.isEmpty, "Back clears secret but keeps public address list")
            model.returnToChains()
            check(model.browserAccount == nil && model.addresses.isEmpty, "Leaving chain clears browser scope")
        }
        // Import scope must survive through the same browser and export APIs.
        let fixtureURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OATH_TEST_LITECOIN_VECTORS"]!)
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
        for network in UTXONetwork.allCases {
            let chain = OathImportChain(rawValue: network.rawValue)!
            for hd in [false, true] {
                let text = fixtures["rootXprv"] as! String
                let bytes = try network.decodeImport(text).bytes
                let key = OathImportedPrivateKey(bytes: bytes, networks: [chain], compressed: true,
                    bitcoinExtendedKey: hd && network == .bitcoin ? text : nil,
                    dogecoinExtendedKey: hd && network == .dogecoin ? text : nil,
                    bitcoinCashExtendedKey: hd && network == .bitcoincash ? text : nil,
                    litecoinExtendedKey: hd && network == .litecoin ? text : nil)
                let id = try await session.addWallet(requestID: UUID(), privateKey: key)
                let account = try await vault.privateKeyAccounts(walletID: id).first!
                let branches = try await vault.privateKeyBranches(walletID: id, accountID: account.id)
                check(branches.allSatisfy { $0.isHD == hd }, "Imported finite and HD scopes must remain distinct")
                for branch in branches {
                    let addresses = try await vault.privateKeyAddresses(walletID: id, accountID: account.id, branchID: branch.id, after: nil)
                    check(addresses.count == (hd ? 20 : 1), "Imports list only addresses they can derive")
                    let key = try await vault.privateKey(walletID: id, accountID: addresses.last!.id, digits: pin)
                    check(try network.decodeImport(key.value).extended == nil, "HD import must export leaf WIF, never root")
                }
            }
        }
        await session.lock()
        do { _ = try await vault.privateKeyAccounts(walletID: walletID); preconditionFailure("Locked vault listed exports") }
        catch { check(true, "Locked vault rejected") }
        print("Passed \(checks) HD private-key browser/vault host checks. Synthetic seed adapter; real public descriptors, leaf-key derivation, database and authorization. No user data, network, simulator or device used.")
    }
}
