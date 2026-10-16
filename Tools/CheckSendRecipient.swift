import Foundation
import OathAnkr
import OathBitcoin
import OathDatabase

@main struct CheckSendRecipient {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ reason: String) { precondition(value, reason); checks += 1 }
        // Public deterministic test vectors, never user wallet material.
        let scalar = Data(repeating: 0, count: 31) + Data([1]), ed = Data(0..<32)
        let tron = try TronSendCrypto.address(privateKey: scalar)
        let xrp = try XrplSendCrypto.address(privateKey: scalar)
        let stellar = try StellarSendCrypto.address(privateKey: ed)
        let ton = try TonSendCrypto.address(publicKey: TonSendCrypto.publicKey(privateKey: ed))
        let evm = "0x52908400098527886E0F7030069857D2E4169EE7"
        var addresses: [OathImportChain: String] = [
            .bitcoin: "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu",
            .bitcoincash: "bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a",
            .near: "recipient.near", .thorchain: "thor1gm00vwsfcp48enm4uv9e5dhm37jtd0ye27wrx0",
            .solana: try SolanaSendCrypto.address(privateKey: ed), .tron: tron, .xrpl: xrp,
            .sui: "0x1", .aptos: "0x1", .stellar: stellar, .ton: ton]
        for (chain, descriptor) in [
            (OathImportChain.litecoin, try LitecoinKeys.singleKey(bytes: scalar, compressed: true)),
            (.dogecoin, try DogecoinKeys.singleKey(bytes: scalar, compressed: true))] {
            addresses[chain] = try BitcoinKeys.addresses(branch: descriptor.branches[0], range: 0..<1)[0].address
        }
        for chain in OathImportChain.allCases where chain.isEVM { addresses[chain] = evm }
        check(Set(addresses.keys) == Set(OathImportChain.allCases), "Every supported chain has an address vector")
        check(Set(OathTrackedSendChain.allCases.map(\.rawValue)) == Set(addresses.keys.map(\.rawValue)), "All send chains audited")
        typealias Rule = OathSendRecipientRules
        let allowed: Set<OathImportChain> = [.bitcoin, .bitcoincash, .litecoin, .dogecoin, .sui]
        for chain in OathImportChain.allCases {
            let owner = addresses[chain]!
            check(OathScanAddress.decode(owner, chain: chain) != nil, "Valid vector: " + chain.id)
            for reference in ["native", "fixture-token"] {
                let expected: Rule.SelfTransferRestriction? = allowed.contains(chain) ? nil
                    : chain == .xrpl || (chain == .tron && reference == "native") ? .network : .wallet
                check(Rule.selfTransferRestriction(sender: owner, recipient: owner, chain: chain, reference: reference) == expected,
                      "Correct native/token scope: " + chain.id)
                check(Rule.selfTransferRestriction(sender: owner, recipient: " \n" + owner + "\n ", chain: chain, reference: reference) == expected,
                      "Pasted whitespace: " + chain.id)
                check(Rule.selfTransferRestriction(sender: owner, recipient: "", chain: chain, reference: reference) == nil,
                      "No warning for empty input")
                check(Rule.selfTransferRestriction(sender: owner, recipient: String(repeating: "x", count: 257), chain: chain, reference: reference) == nil,
                      "Bounded invalid input")
            }
        }
        check(Rule.selfTransferRestriction(sender: tron, recipient: tron, chain: .tron, reference: "1002000") == .network, "TRC-10 prohibited")
        check(Rule.selfTransferRestriction(sender: tron, recipient: tron, chain: .tron, reference: TronIdentity.usdt) == .wallet, "TRC-20 is not a blanket network restriction")
        check(Rule.selfTransferRestriction(sender: tron, recipient: try TronIdentity.callAddress(tron), chain: .tron, reference: "native") == .network, "TRON hex aliases")
        check(Rule.selfTransferRestriction(sender: evm, recipient: evm.lowercased(), chain: .ethereum, reference: "native") == .wallet, "EVM checksum aliases")
        check(Rule.selfTransferRestriction(sender: "0x1", recipient: "0x" + String(repeating: "0", count: 63) + "1", chain: .aptos, reference: "native") == .wallet, "Move padding aliases")
        for bounceable in [false, true] {
            check(Rule.selfTransferRestriction(sender: ton, recipient: try TonIdentity.friendly(ton, bounceable: bounceable), chain: .ton, reference: "native") == .wallet, "TON friendly aliases")
        }
        // Routing tags do not create a different underlying XRP/Stellar account.
        let xpayload = Data([0x05, 0x44]) + (try XrplIdentity.accountBytes(xrp)) + Data([1, 42, 0, 0, 0, 0, 0, 0, 0])
        let xaddress = OathScanAddress.base58Encode(xpayload, alphabet: OathScanAddress.rippleAlphabet)
        let muxed = OathScanAddress.strKey((try StellarIdentity.bytes(stellar, version: 48)) + Data([0,0,0,0,0,0,0,42]), version: 96)
        check(Rule.selfTransferRestriction(sender: xrp, recipient: xaddress, chain: .xrpl, reference: "native") == .network, "X-address tag cannot bypass")
        check(Rule.selfTransferRestriction(sender: stellar, recipient: muxed, chain: .stellar, reference: "native") == .wallet, "Muxed ID cannot bypass")
        let otherTron = try TronSendCrypto.address(privateKey: Data(repeating: 2, count: 32))
        check(Rule.selfTransferRestriction(sender: tron, recipient: otherTron, chain: .tron, reference: "native") == nil, "Another owned account remains a different recipient")
        let otherXrp = try XrplSendCrypto.address(privateKey: Data(repeating: 2, count: 32))
        check(Rule.selfTransferRestriction(sender: xrp, recipient: otherXrp, chain: .xrpl, reference: "native") == nil, "A different XRP account remains valid")
        check(Rule.selfTransferRestriction(sender: "sender.near", recipient: "recipient.near", chain: .near, reference: "wrap.near") == nil, "A different NEAR token recipient remains valid")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recipient-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        await OathDataEnvironment.shared.set(db)
        for chain in OathImportChain.allCases {
            let decimals = chain == .aptos ? 8 : 6
            try await db.seed(networks: [.init(id: chain.id, name: chain.name, family: "account", symbol: "TEST", decimals: decimals,
                derivationPath: "test", logo: "test", sortOrder: 0)], assets: [.init(id: chain.id + ":native", networkID: chain.id,
                reference: "native", name: "Fixture", symbol: "TEST", decimals: decimals)])
        }
        for (wallet, tronAddress) in [("one", tron), ("two", otherTron)] {
            let accounts = OathImportChain.allCases.map { chain in AccountRecord(id: wallet + chain.id, walletID: wallet,
                networkID: chain.id, address: chain == .tron ? tronAddress : addresses[chain]!, derivationPath: "test") }
            try await db.importWalletIfNeeded(.init(id: wallet, name: "Fixture", kind: "hd", vaultReference: "test-" + wallet, createdAt: 1), accounts: accounts)
        }
        let inventory = try JSONDecoder().decode(TronInventory.self, from: JSONSerialization.data(withJSONObject: [
            "owner": tron, "holdings": [["token": ["reference": "native", "name": "TRON", "symbol": "TRX", "decimals": 6], "amount": "10000000"]],
            "failedReferences": [], "excludedNFTs": [], "discoveryComplete": true,
            "observedAt": Date.now.timeIntervalSinceReferenceDate, "raw": ""
        ]))
        let ticket = try await db.beginTronSync(accountID: "onetron")
        try await db.commitTronInventory(inventory, ticket: ticket, catalog: [:])
        func xrpInventory(_ balance: String, time: Double) throws -> XrplInventory {
            try JSONDecoder().decode(XrplInventory.self,from:JSONSerialization.data(withJSONObject:[
                "owner":xrp,"ledger":["hash":String(repeating:"A",count:64),"height":500,"timestamp":time],"exists":true,
                "holdings":[["reference":"native","amount":balance,"raw":NSNull()]],
                "observedAt":time-Date.timeIntervalBetween1970AndReferenceDate,"raw":""
            ]))
        }
        let xrpTicket = try await db.beginXrplSync(accountID:"onexrpl"), observed = Date.now.timeIntervalSince1970
        try await db.commitXrplInventory(xrpInventory("1000000",time:observed),ticket:xrpTicket,catalog:.empty)
        // The inventory can aggregate multiple Aptos fungible stores using
        // arbitrary-precision balances. A single transfer still takes a u64.
        let aptosReference = try AptosIdentity.address("0x456")
        let aptosInventory = try JSONDecoder().decode(AptosInventory.self, from: JSONSerialization.data(withJSONObject: [
            "owner": try AptosIdentity.address("0x1"), "holdings": [
                ["token": ["reference": "native", "name": "Aptos", "symbol": "APT", "decimals": 8, "verified": true], "amount": "100000000"],
                ["token": ["reference": aptosReference, "name": "Fixture token", "symbol": "TEST", "decimals": 0, "verified": true], "amount": "18446744073709551616"]
            ], "failedReferences": [], "discoveryComplete": true, "ledgerVersion": 1,
            "observedAt": Date.now.timeIntervalSinceReferenceDate, "raw": ""
        ]))
        let aptosTicket = try await db.beginAptosSync(accountID: "oneaptos")
        let aptosCatalog = try JSONDecoder().decode(AptosCatalog.self, from: JSONSerialization.data(withJSONObject: [
            "tokens": [aptosReference: try JSONSerialization.jsonObject(with: JSONEncoder().encode(aptosInventory.holdings[1].token))],
            "aliases": [:]
        ]))
        try await db.commitAptosInventory(aptosInventory, ticket: aptosTicket, catalog: aptosCatalog)
        let defaults = UserDefaults(suiteName: "recipient-tests-" + UUID().uuidString)!
        let model = OathSendModel(walletID: "one", preferences: defaults)
        var observe = Task { await model.observe(currency: "USD") }
        defer { observe.cancel() }
        func ready() async throws {
            for _ in 0..<200 {
                if !model.loading && model.snapshot?.wallet.id == model.walletID { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("Snapshot timeout")
        }
        try await ready()
        for chain in OathImportChain.allCases {
            let holding = model.holdings.first { $0.networkID == chain.id }!
            model.choose(holding)
            model.address = addresses[chain]!
            check((model.selfTransferRestriction == nil) == allowed.contains(chain), "Immediate typed validation: " + chain.id)
            check(model.validateRecipient() == allowed.contains(chain), "Continue guard: " + chain.id)
            if !allowed.contains(chain) {
                check(!model.prepareReview(locale: Locale(identifier: "en_US")) && !model.path.contains(.review), "Review cannot bypass recipient")
            }
            model.address = ""
            check(model.selfTransferRestriction == nil, "Clearing input clears live warning")
        }
        let aptosToken = model.holdings.first { $0.networkID == "aptos" && $0.reference == aptosReference }!
        model.choose(aptosToken)
        model.address = try AptosIdentity.address("0x2")
        for digit in "18446744073709551616" { model.enter(.digit(digit.wholeNumberValue!), locale: Locale(identifier: "en_US")) }
        check(model.amountFailure(locale: Locale(identifier: "en_US")) == .invalid,
              "An Aptos amount exceeding u64 must fail on the amount screen, even below an aggregated balance")
        check(!model.prepareReview(locale: Locale(identifier: "en_US")), "Out-of-range Aptos amounts cannot reach quote preparation")
        model.useBalance()
        check(model.amountFailure(locale: Locale(identifier: "en_US")) == .invalid,
              "Max must not bypass the Aptos transaction amount bound")
        for amount in ["1", String(UInt64.max)] {
            model.choose(aptosToken); model.address = try AptosIdentity.address("0x2")
            for digit in amount { model.enter(.digit(digit.wholeNumberValue!), locale: Locale(identifier: "en_US")) }
            check(model.amountFailure(locale: Locale(identifier: "en_US")) == nil,
                  "Aptos transfer boundaries are exact, without Decimal rounding")
            check(model.prepareReview(locale: Locale(identifier: "en_US")) && model.reviewAtomic == amount,
                  "Valid Aptos boundary amounts reach review unchanged")
        }
        try await db.savePrices([.init(assetID: aptosToken.assetID, currency: "USD", value: "2",
                                      observedAt: Date.now.timeIntervalSince1970, source: "fixture")])
        for _ in 0..<200 where model.price != 2 { try await Task.sleep(for: .milliseconds(10)) }
        check(model.price == 2, "Fiat regression uses an observed portfolio quote")
        model.choose(aptosToken); model.address = try AptosIdentity.address("0x2")
        if !model.fiatEntry { model.switchUnit(locale: Locale(identifier: "en_US")) }
        check(model.fiatEntry, "Fiat validation must exercise the fiat entry branch")
        model.enter(.clear, locale: Locale(identifier: "en_US"))
        for digit in "36893488147419103232" { model.enter(.digit(digit.wholeNumberValue!), locale: Locale(identifier: "en_US")) }
        check(model.amountFailure(locale: Locale(identifier: "en_US")) == .invalid,
              "Fiat conversion cannot bypass Aptos transaction bounds")
        check(!model.prepareReview(locale: Locale(identifier: "en_US")), "Out-of-range fiat stays on the amount screen")
        model.enter(.clear, locale: Locale(identifier: "en_US")); model.enter(.digit(2), locale: Locale(identifier: "en_US"))
        check(model.prepareReview(locale: Locale(identifier: "en_US")) && model.reviewAtomic == "1",
              "A valid fiat amount still freezes one exact native unit")
        model.useBalance(); model.switchUnit(locale: Locale(identifier: "en_US"))
        check(model.fiatEntry && model.amountFailure(locale: Locale(identifier: "en_US")) == .invalid,
              "Switching Max to fiat preserves the amount bound")
        model.choose(model.holdings.first { $0.networkID == "tron" }!)
        let entry = try JSONDecoder().decode(SendRecipient.self, from: JSONSerialization.data(withJSONObject:
            ["id":"entry", "contactID":"contact", "name":"Fixture", "label":"", "address":tron, "networkID":"tron"]))
        model.setRecipient(entry)
        check(model.selfTransferRestriction == .network && !model.validateRecipient(), "Address-book selection blocked before amount")
        check(model.receiveScan(.init(original: tron, networks: [.tron]), chain: .tron), "Scanner decodes self address")
        check(!model.validateRecipient() && model.path == [.recipient], "Scanner cannot advance to amount")
        model.address = otherTron
        check(model.selfTransferRestriction == nil && model.validateRecipient(), "Editing to another recipient clears warning")
        model.enter(.digit(1), locale: Locale(identifier: "en_US"))
        check(model.amountFailure(locale: Locale(identifier: "en_US")) == nil, "Review regression uses a valid funded amount")
        model.address = tron
        check(!model.prepareReview(locale: Locale(identifier: "en_US")) && model.path == [.recipient], "A valid amount cannot bypass the self-recipient guard")
        model.address = otherTron
        check(model.prepareReview(locale: Locale(identifier: "en_US")) && model.path.last == .review, "The same amount can proceed to another account")
        model.memo = "invalid"
        check(!model.validateRecipient() && model.memoError, "Existing memo validation preserved")
        // Exercise explicit reserve-closure consent on the production model.
        model.choose(model.holdings.first { $0.networkID == "xrpl" }!)
        model.address = otherXrp
        let closure = XrplSendPlan(network:.mainnet,sender:xrp,recipient:otherXrp,reference:"native",
            requestedAmount:"1000000",amount:"800000",assetDebit:"800000",assetBalance:"1000000",nativeBalance:1_000_000,
            reserve:1_000_000,fee:200_000,sequence:42,firstLedger:500,lastLedger:520,recipientReserve:0,accountDeletionFee:200_000)
        check(model.canOfferXrplAccountClosure,"Only the final XRP offers closure")
        model.useBalance()
        check(model.xrplAccountClosure == nil,"Max alone is not consent")
        check(model.useAccountClosure(closure),"Explicit consent binds matching source and destination")
        check(model.amount == "0.8" && model.maximumAmount?.atomic == "800000","Review shows net recovery")
        check(model.prepareReview(locale:Locale(identifier:"en_US")),"Explicit closure proceeds to review")
        check(model.xrplAccountClosure == closure && !model.reviewNeedsUpdate,"Review keeps exact closure intent")
        model.enter(.clear,locale:Locale(identifier:"en_US"))
        check(model.xrplAccountClosure == nil,"Manual amount edit cancels closure consent")
        check(model.useAccountClosure(closure),"Can explicitly choose again")
        model.memo = "1"
        check(model.xrplAccountClosure == nil && !model.useAccountClosure(closure),"Destination tag change invalidates consent")
        model.memo = "";check(model.useAccountClosure(closure),"Matching tag restored")
        model.address = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
        check(model.xrplAccountClosure == nil,"Recipient edit clears consent")
        model.address = otherXrp;check(model.useAccountClosure(closure),"Source still bound")
        model.useBalance();check(model.xrplAccountClosure == nil,"A new ordinary Max cannot retain old closure consent")
        check(model.useAccountClosure(closure),"Explicit consent before balance update")
        try await db.commitXrplInventory(xrpInventory("1000001",time:observed+1),ticket:xrpTicket,catalog:.empty)
        for _ in 0..<200 where model.holding?.amountAtomic != "1000001" { try await Task.sleep(for:.milliseconds(10)) }
        check(!model.canOfferXrplAccountClosure && !model.useAccountClosure(closure),"No reserve offer when balance exceeds 1 XRP")
        check(model.reviewNeedsUpdate,"An incoming payment invalidates closure review")
        model.changeRecipient();check(model.xrplAccountClosure == nil,"Back to recipient cancels consent")

        // XRP's issued-token scale is an internal 96-digit representation, not
        // an instruction to accept 96 significant digits in a Payment. Exercise
        // every editable route through the actual model and observed database.
        let issuedReference = "USD." + otherXrp
        let issuedBalance = try XrplIdentity.issuedAmount("123456789.1234567")
        let issuedInventory = try JSONDecoder().decode(XrplInventory.self, from: JSONSerialization.data(withJSONObject: [
            "owner": xrp, "ledger": ["hash": String(repeating: "B", count: 64), "height": 501, "timestamp": observed + 2], "exists": true,
            "holdings": [["reference": "native", "amount": "1000001", "raw": NSNull()],
                         ["reference": issuedReference, "amount": issuedBalance, "raw": NSNull()]],
            "observedAt": observed + 2 - Date.timeIntervalBetween1970AndReferenceDate, "raw": ""
        ]))
        try await db.commitXrplInventory(issuedInventory, ticket: xrpTicket,
            catalog: XrplCatalog(ids: [issuedReference: "fixture-issued"]))
        for _ in 0..<200 where !model.holdings.contains(where: { $0.reference == issuedReference }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let issuedHolding = model.holdings.first(where: { $0.reference == issuedReference }) else {
            preconditionFailure("Issued-token snapshot timeout")
        }
        let inputLocale = Locale(identifier: "en_US")
        func issuedEntry(_ input: String) {
            model.choose(issuedHolding); model.address = otherXrp
            if model.fiatEntry { model.switchUnit(locale: inputLocale) }
            for character in input {
                model.enter(character == "." ? .decimal : .digit(character.wholeNumberValue!), locale: inputLocale)
            }
        }
        for value in ["0.1234567890123456", "123456789.1234567", "0." + String(repeating: "0", count: 80) + "1"] {
            issuedEntry(value)
            let expected = try XrplIdentity.issuedAmount(value)
            check(model.amountFailure(locale: inputLocale) == nil, "Valid issued-token precision accepted")
            check(model.prepareReview(locale: inputLocale) && model.reviewAtomic == expected,
                  "Issued-token review freezes the exact 16-digit or minimum-exponent value")
            check(try XrplIdentity.issuedAmount(XrplSendAmount.issuedValue(model.reviewAtomic!)) == expected,
                  "Every accepted issued value round-trips into the production transaction encoder")
        }
        for invalid in ["0.12345678901234567", "0." + String(repeating: "0", count: 81) + "1"] {
            issuedEntry(invalid)
            check(model.amountFailure(locale: inputLocale) == .precision && !model.prepareReview(locale: inputLocale),
                  "Precision and minimum-exponent violations cannot reach quote preparation")
        }
        model.choose(issuedHolding); model.address = otherXrp; model.useBalance()
        check(model.prepareReview(locale: inputLocale) && model.reviewAtomic == issuedBalance,
              "Issued-token Max preserves the exact observed balance")
        try await db.savePrices([.init(assetID: issuedHolding.assetID, currency: "USD", value: "3",
                                      observedAt: observed + 3, source: "fixture")])
        for _ in 0..<200 where model.price != 3 { try await Task.sleep(for: .milliseconds(10)) }
        check(model.price == 3, "Issued-token fiat cases use an observed price")
        model.choose(issuedHolding); model.address = otherXrp
        if !model.fiatEntry { model.switchUnit(locale: inputLocale) }
        model.enter(.digit(1), locale: inputLocale)
        let fiatExpected = try XrplIdentity.issuedAmount("0.3333333333333333")
        check(model.prepareReview(locale: inputLocale) && model.reviewAtomic == fiatExpected,
              "Fiat rounds down to a representable issued amount before review")
        model.switchUnit(locale: inputLocale)
        check(try !model.fiatEntry && model.atomic(locale: inputLocale) == fiatExpected,
              "Switching fiat to native preserves the representable issued amount")
        model.useBalance(); model.switchUnit(locale: inputLocale)
        check(try model.fiatEntry && model.atomic(locale: inputLocale) == issuedBalance,
              "Switching Max to fiat never recomputes its exact atomic intent")
        observe.cancel(); await observe.value
        model.selectWallet("two")
        observe = Task { await model.observe(currency: "USD") }
        try await ready()
        model.choose(model.holdings.first { $0.networkID == "tron" }!)
        model.address = tron
        check(model.validateRecipient() && model.selfTransferRestriction == nil, "Switching sender does not keep stale self warning")
        model.address = otherTron
        check(!model.validateRecipient() && model.selfTransferRestriction == .network, "Active account is used after wallet switch")
        print("Passed \(checks) recipient checks across \(OathImportChain.allCases.count) networks. Host only; no simulator, device or network.")
    }
}
