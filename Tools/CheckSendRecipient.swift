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
            .polkadot: try PolkadotIdentity.address(publicKey: ed),
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
        let allowed: Set<OathImportChain> = [.bitcoin, .bitcoincash, .litecoin, .dogecoin, .sui, .polkadot]
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
        check(Rule.selfTransferRestriction(sender: evm, recipient: try FilecoinIdentity.delegated(evm), chain: .filecoin, reference: "native") == .wallet, "Filecoin f410 aliases")
        for chain in [OathImportChain.chiliz, .filecoin, .sei, .zerog, .iotex] {
            var aliases = [evm, evm.lowercased()]
            if chain == .filecoin { aliases.append(try FilecoinIdentity.delegated(evm)) }
            if chain == .iotex {
                let native = try IoTeXIdentity.native(evm)
                aliases += [native, native.uppercased()]
            }
            for source in aliases {
                for destination in aliases {
                    for reference in ["native", "0x" + String(repeating: "3", count: 40)] {
                        check(Rule.selfTransferRestriction(sender: source, recipient: destination, chain: chain, reference: reference) == .wallet,
                              "New-chain native/token account aliases: " + chain.id)
                    }
                }
            }
        }
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

        let secondKey = Data(repeating: 2, count: 32)
        var otherAddresses: [OathImportChain: String] = [
            .bitcoin: "1LqBGSKuX5yYUonjxT5qGfpUsXKYYWeabA",
            .bitcoincash: "1LqBGSKuX5yYUonjxT5qGfpUsXKYYWeabA",
            .near: "different-recipient.near", .tron: otherTron, .xrpl: otherXrp,
            .polkadot: try PolkadotIdentity.address(publicKey: secondKey),
            .solana: try SolanaSendCrypto.address(privateKey: secondKey),
            .stellar: try StellarSendCrypto.address(privateKey: secondKey),
            .sui: try SuiSendCrypto.address(privateKey: secondKey),
            .aptos: try AptosSendCrypto.address(privateKey: secondKey),
            .ton: try TonSendCrypto.address(publicKey: TonSendCrypto.publicKey(privateKey: secondKey)),
            .thorchain: try ThorchainSendCrypto.address(publicKey: ThorchainSendCrypto.publicKey(privateKey: secondKey), network: .mainnet)]
        for (chain, descriptor) in [
            (OathImportChain.litecoin, try LitecoinKeys.singleKey(bytes: secondKey, compressed: true)),
            (.dogecoin, try DogecoinKeys.singleKey(bytes: secondKey, compressed: true))] {
            otherAddresses[chain] = try BitcoinKeys.addresses(branch: descriptor.branches[0], range: 0..<1)[0].address
        }
        for chain in OathImportChain.allCases where chain.isEVM { otherAddresses[chain] = "0x3333333333333333333333333333333333333333" }

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
        for chain in OathImportChain.allCases {
            let multisigKind = chain.isEVM ? "evmMultisig" : chain == .bitcoincash ? "bitcoinCashMultisig" : chain.id + "Multisig"
            for kind in chain == .polkadot ? ["privateKey"] : ["privateKey", multisigKind] {
                let id = "direct-" + chain.id + kind
                try await db.importWalletIfNeeded(.init(id: id, name: "Fixture", kind: kind, vaultReference: id, createdAt: 1),
                    accounts: [.init(id: id, walletID: id, networkID: chain.id, address: addresses[chain]!, derivationPath: "fixture")])
                let snapshot = try await db.snapshot(walletID: id, currency: "USD")
                let direct = OathSendModel(walletID: id, preferences: defaults)
                direct.prepareInitialSelection(from: snapshot)
                let nativeOnly = [OathImportChain.bitcoin, .bitcoincash, .dogecoin, .litecoin].contains(chain)
                check(nativeOnly ? (direct.path == [.recipient] && direct.holding?.accountID == id)
                                 : (direct.path.isEmpty && direct.holding == nil),
                      "Only native-only networks bypass asset selection: " + chain.id + kind)
                direct.path = []
                direct.prepareInitialSelection(from: snapshot)
                check(direct.path.isEmpty, "Back navigation is not redirected by another snapshot")
            }
        }
        // Actual parser -> asset selection -> recipient/amount model, backed by
        // SQLite for every supported native chain and every token-capable chain.
        let networkIDs = Dictionary(uniqueKeysWithValues: OathTokenNetwork.all.filter { $0.chain.isEVM }.compactMap { row in row.chainID.map { ($0, row.chain) } })
        let paymentParser = OathScanParser(validator: nil, evmNetworks: networkIDs)
        for chain in OathImportChain.allCases {
            let id = "payment-" + chain.id, destination = addresses[chain]!
            try await db.importWalletIfNeeded(.init(id: id, name: "Fixture", kind: "privateKey", vaultReference: id, createdAt: 1),
                accounts: [.init(id: id, walletID: id, networkID: chain.id, address: destination, derivationPath: "fixture")])
            let amount = "2.125", decimals = chain == .aptos ? 8 : 6
            let atomic = try OathSendAmount.atomic(amount, decimals: decimals, locale: Locale(identifier: "en_US_POSIX"))
            let uri: String
            if chain.isEVM {
                uri = "ethereum:\(destination)@\(networkIDs.first { $0.value == chain }!.key)?value=\(atomic)"
            } else if chain == .ton { uri = "ton://transfer/\(destination)?amount=\(atomic)" }
            else { uri = "\(chain.id):\(destination.replacingOccurrences(of: "bitcoincash:", with: ""))?amount=\(amount)" }
            guard case .recipient(let payment) = paymentParser.parse(uri + "&label=Shop&message=Order%20123") else { preconditionFailure("Native payment parser: " + chain.id) }
            var snapshot = try await db.snapshot(walletID: id, currency: "USD")
            let composer = OathSendModel(walletID: id, scannedRecipient: payment, preferences: defaults)
            composer.prepareInitialSelection(from: snapshot)
            check(composer.path == (allowed.contains(chain) ? [.amount] : [.recipient]) && composer.holding?.reference == "native", "Exact native payment resolves directly with self-transfer validation: " + chain.id)
            composer.choose(snapshot.holdings.first { $0.reference == "native" }!, from: snapshot, scannedRecipient: payment)
            check(composer.path == (allowed.contains(chain) ? [.amount] : [.recipient]) && composer.address == payment.decoded(on: chain)?.address, "Recipient prefilled and validated: " + chain.id)
            check(composer.paymentNote == "Shop\nOrder 123", "Payment notes survive composer: " + chain.id)
            check(composer.amount == amount && !composer.fiatEntry && composer.maximumAmount == nil, "Exact native units prefilled: " + chain.id)
            check(try composer.atomic(locale: Locale(identifier: "en_US_POSIX")) == atomic, "Native amount survives composer: " + chain.id)
            let nativeHolding = snapshot.holdings.first { $0.reference == "native" }!
            let directScan = OathScannedRecipient(original: otherAddresses[chain]!, networks: [chain], amount: amount,
                label: "Shop", message: "Order 123")
            let assetComposer = OathSendModel(walletID: id, preferences: defaults)
            check(assetComposer.startScannedSend(nativeHolding, from: snapshot, recipient: directScan), "Asset scan passes recipient validation: " + chain.id)
            check(assetComposer.path == ([.xrpl, .stellar].contains(chain) ? [.recipient] : [.amount]) && assetComposer.holdingID == nativeHolding.id && assetComposer.amount == amount,
                  "Asset scan opens amount with current holding and exact amount: " + chain.id)
            check(assetComposer.address == directScan.decoded(on: chain)?.address && assetComposer.paymentNote == "Shop\nOrder 123",
                  "Asset scan retains recipient and notes: " + chain.id)
            let selfScanAllowed = assetComposer.startScannedSend(nativeHolding, from: snapshot, recipient: payment)
            check(selfScanAllowed == allowed.contains(chain), "Asset shortcut preserves self-transfer restrictions: " + chain.id)
            check(assetComposer.path == (selfScanAllowed ? [.amount] : [.recipient]), "Rejected self scan stays on recipient: " + chain.id)
            let malformed = OathScannedRecipient(original: "not an address", networks: [chain])
            check(!assetComposer.startScannedSend(nativeHolding, from: snapshot, recipient: malformed) && assetComposer.path == [.recipient],
                  "Invalid scan cannot advance to amount: " + chain.id)
            let otherWallet = OathSendModel(walletID: "unrelated-wallet", preferences: defaults)
            check(!otherWallet.startScannedSend(nativeHolding, from: snapshot, recipient: directScan) && otherWallet.path.isEmpty,
                  "Stale wallet scan cannot route: " + chain.id)
            if chain.supportsTokens {
                let ref = "fixture-payment-token"
                let tokenDecimals = chain.isEVM ? 18 : [.near: 24, .xrpl: 96, .stellar: 7, .sui: 9, .aptos: 8][chain, default: 6]
                try await db.trackAsset(.init(id: chain.id + ":" + ref, networkID: chain.id, reference: ref,
                    name: "Fixture token", symbol: "USDT", decimals: tokenDecimals), walletID: id)
                snapshot = try await db.snapshot(walletID: id, currency: "USD")
                guard case .recipient(let request) = paymentParser.parse("usdt:\(destination)?amount=200.125") else { preconditionFailure("Token payment parser: " + chain.id) }
                let tokenComposer = OathSendModel(walletID: id, scannedRecipient: request, preferences: defaults)
                tokenComposer.prepareInitialSelection(from: snapshot)
                check(tokenComposer.path.isEmpty, "Token scan retains selection: " + chain.id)
                let ranked = request.prioritized(snapshot.holdings, network: { $0.networkID }, reference: { $0.reference }, symbol: { $0.symbol })
                check(ranked.first?.reference == ref && ranked.count == snapshot.holdings.count, "Matching token promoted without losing alternatives: " + chain.id)
                tokenComposer.choose(ranked.first!, from: snapshot, scannedRecipient: request)
                check(tokenComposer.path == (allowed.contains(chain) ? [.amount] : [.recipient]) && tokenComposer.address == request.decoded(on: chain)?.address && tokenComposer.amount == "200.125" && !tokenComposer.fiatEntry, "Token recipient and amount prefilled: " + chain.id)
                let expectedTokenAtomic = "200125" + String(repeating: "0", count: tokenDecimals - 3)
                check(try tokenComposer.atomic(locale: Locale(identifier: "en_US_POSIX")) == expectedTokenAtomic, "Token quantity preserved at its metadata scale: " + chain.id)
                let tokenScan = OathScannedRecipient(original: otherAddresses[chain]!, networks: [chain],
                    amount: "200.125", tokenSymbol: "USDT", label: "Invoice")
                check(assetComposer.startScannedSend(ranked.first!, from: snapshot, recipient: tokenScan), "Selected token scan validates: " + chain.id)
                check(assetComposer.path == ([.xrpl, .stellar].contains(chain) ? [.recipient] : [.amount]) && assetComposer.amount == "200.125" && assetComposer.paymentNote == "Invoice",
                      "Selected token and invoice go directly to amount: " + chain.id)
                check(!assetComposer.startScannedSend(nativeHolding, from: snapshot, recipient: tokenScan), "Different token needs explicit picker selection: " + chain.id)
                tokenComposer.choose(snapshot.holdings.first { $0.reference == "native" }!, from: snapshot, scannedRecipient: request)
                check(tokenComposer.amount.isEmpty && !tokenComposer.address.isEmpty && !tokenComposer.addressError, "Changing asset retains address but never reuses wrong quantity: " + chain.id)
                // Direct recipient scans remain strict, unlike explicit picker selection.
                check(!tokenComposer.receiveScan(request, chain: chain), "Recipient scan cannot change selected asset: " + chain.id)
            }
        }
        // ChangeNOW's address-plus-query format carries human units and no
        // asset identity. The selected asset supplies its real decimal scale.
        try await db.saveAsset(.init(id: "arc:native", networkID: "arc", reference: "native",
            name: "USDC", symbol: "USDC", decimals: 18))
        let arcSnapshot = try await db.snapshot(walletID: "payment-arc", currency: "USD")
        let arcNative = arcSnapshot.holdings.first { $0.reference == "native" }!
        let arcDestination = "0x3333333333333333333333333333333333333333"
        for uri in [arcDestination + "?amount=50", "arc:" + arcDestination + "?amount=50",
                    "ethereum:" + arcDestination + "@5042?value=5e19",
                    "ethereum:" + ArcIdentity.usdc + "@5042/transfer?address=" + arcDestination + "&uint256=5e7"] {
            guard case .recipient(let payment) = paymentParser.parse(uri) else { preconditionFailure("Arc payment") }
            let composer = OathSendModel(walletID: arcSnapshot.wallet.id, scannedRecipient: payment, preferences: defaults)
            composer.prepareInitialSelection(from: arcSnapshot)
            if payment.hasExactAsset {
                check(composer.path == [.amount] && composer.holdingID == arcNative.id, "Exact Arc USDC request routes to native amount")
            } else {
                check(composer.path.isEmpty && composer.holding == nil, "Bare Arc invoice must not invent a network")
                composer.choose(arcNative, from: arcSnapshot, scannedRecipient: payment)
            }
            check(composer.path == [.amount] && composer.amount == "50", "Arc human/native/ERC20 units agree")
            check(try composer.atomic(locale: Locale(identifier: "en_US_POSIX")) == "50000000000000000000", "Arc USDC signs in native 18-decimal units")
            composer.path = []
            composer.prepareInitialSelection(from: arcSnapshot)
            check(composer.path.isEmpty, "Portfolio refresh must not redirect back navigation")
        }
        for chain in OathImportChain.allCases {
            guard case .recipient(let payment) = paymentParser.parse(otherAddresses[chain]! + "?amount=1.125") else { preconditionFailure("Bare payment") }
            let snapshot = try await db.snapshot(walletID: "payment-" + chain.id, currency: "USD")
            let composer = OathSendModel(walletID: snapshot.wallet.id, scannedRecipient: payment, preferences: defaults)
            composer.prepareInitialSelection(from: snapshot)
            if chain.supportsTokens || payment.networks.count != 1 {
                check(composer.path.isEmpty, "Unspecified asset/network keeps selection: " + chain.id)
            }
            composer.choose(snapshot.holdings.first { $0.reference == "native" }!, from: snapshot, scannedRecipient: payment)
            check(composer.path == ([.xrpl, .stellar].contains(chain) ? [.recipient] : [.amount]) && composer.amount == "1.125", "Bare invoice respects routing-field entry after selection: " + chain.id)
        }
        // Routing values are optional for manual Continue, but a scan must leave
        // XRP/Stellar recipients editable when the routing information is absent.
        for chain in [OathImportChain.xrpl, .stellar] {
            let snapshot = try await db.snapshot(walletID: "payment-" + chain.id, currency: "USD")
            for holding in snapshot.holdings {
                let missing = OathScannedRecipient(original: otherAddresses[chain]!, networks: [chain],
                    amount: "2.5", token: holding.reference)
                let composer = OathSendModel(walletID: snapshot.wallet.id, scannedRecipient: missing, preferences: defaults)
                composer.prepareInitialSelection(from: snapshot)
                check(composer.path == [.recipient] && composer.amount == "2.5" && composer.memo.isEmpty,
                      "Home scan leaves missing routing information editable: " + chain.id)
                check(composer.validateRecipient() && !composer.validateScannedRecipient(),
                      "Missing routing information is not an invalid address or a mandatory memo")
                check(!composer.addressError && !composer.memoError && composer.recipientDetails.isEmpty,
                      "Missing routing information has no error or empty capsule")
                check(composer.startScannedSend(holding, from: snapshot, recipient: missing) && composer.path == [.recipient],
                      "Asset scan cannot skip missing routing information")
                for memo in ["0", "42"] {
                    var supplied = missing; supplied.memo = memo
                    if chain == .stellar { supplied.memoType = "id" }
                    composer.choose(holding, from: snapshot, scannedRecipient: supplied)
                    check(composer.path == [.amount] && composer.memo == memo && composer.validateScannedRecipient(),
                          "Supplied routing value including zero skips recipient entry")
                    let detail = composer.recipientDetails.first
                    check(detail?.kind == .memo && detail?.value == memo && detail?.isEditable == true,
                          "Amount capsule retains the complete routing value")
                    check(detail?.title == (chain == .xrpl ? .sendDestinationTagLabel : .stellarMemoID),
                          "Routing capsule uses the correct chain and memo-type label")
                    composer.changeRecipient()
                    check(composer.path == [.recipient] && composer.amount == "2.5" && composer.memo == memo,
                          "Editing a routing value preserves amount and recipient")
                    composer.memo = "123"
                    check(composer.validateRecipient() && composer.recipientDetails.first?.value == "123",
                          "Updated routing value reaches the amount details")
                    composer.memo = ""
                    check(composer.validateRecipient() && !composer.validateScannedRecipient() && composer.recipientDetails.isEmpty,
                          "Removing a routing value removes its capsule without requiring a memo")
                    composer.memo = chain == .xrpl ? "4294967296" : "18446744073709551616"
                    check(!composer.validateScannedRecipient() && composer.memoError,
                          "Overflowing routing values cannot advance")
                }
            }
            let holding = snapshot.holdings.first { $0.reference == "native" }!
            let embedded: String
            if chain == .xrpl {
                embedded = OathScanAddress.base58Encode(Data([5,68]) + (try XrplIdentity.accountBytes(otherAddresses[chain]!)) +
                    Data([1,0,0,0,0,0,0,0,0]), alphabet: OathScanAddress.rippleAlphabet)
            } else {
                embedded = OathScanAddress.strKey((try StellarIdentity.bytes(otherAddresses[chain]!, version: 48)) +
                    Data(repeating: 0, count: 8), version: 96)
            }
            guard case .recipient(let request) = paymentParser.parse(embedded) else { preconditionFailure("Embedded routing") }
            let composer = OathSendModel(walletID: snapshot.wallet.id, preferences: defaults)
            check(composer.startScannedSend(holding, from: snapshot, recipient: request) && composer.path == [.amount],
                  "Embedded zero tag or memo ID skips recipient entry")
            check(composer.memo == "0" && composer.recipientDetails.first?.value == "0", "Embedded routing value is visible")
            composer.choose(holding, from: snapshot)
            check(composer.receiveScan(request, chain: chain) && composer.validateScannedRecipient(),
                  "Recipient-page scanner uses the same embedded-routing rule")
        }
        for chain in [OathImportChain.ton, .solana, .thorchain, .stellar] {
            let snapshot = try await db.snapshot(walletID: "payment-" + chain.id, currency: "USD")
            let holding = snapshot.holdings.first { $0.reference == "native" }!
            let memo = chain == .stellar ? "Order 123" : String(repeating: "Invoice ", count: 10)
            let request = OathScannedRecipient(original: otherAddresses[chain]!, networks: [chain], amount: "1",
                memo: memo, label: "Shop", message: "Local request note")
            let composer = OathSendModel(walletID: snapshot.wallet.id, preferences: defaults)
            check(composer.startScannedSend(holding, from: snapshot, recipient: request) && composer.path == [.amount],
                  "Memo-bearing asset request still routes directly")
            check(composer.recipientDetails.first?.value == memo && composer.recipientDetails.first?.isEditable == true,
                  "Long memo remains complete for the detail sheet")
            let note = composer.recipientDetails.last
            check(note?.kind == .paymentNote && note?.value == "Shop\nLocal request note" && note?.isEditable == false,
                  "Request notes stay separate from the transmitted memo")
            if chain == .ton {
                guard case .recipient(let gram) = paymentParser.parse("gram://transfer/" + otherAddresses[chain]! + "?amount=1000000000&text=Invoice%2042") else { preconditionFailure("GRAM comment") }
                check(composer.receiveScan(gram, chain: chain) && composer.recipientDetails.first?.value == "Invoice 42",
                      "GRAM comment appears as the TON memo")
            }
            composer.changeRecipient()
            check(composer.memo == memo || chain == .ton, "Editing preserves memo contents")
            composer.choose(holding, from: snapshot)
            check(composer.recipientDetails.isEmpty, "Changing assets discards previous recipient details")
        }
        for chain in [OathImportChain.bitcoin, .litecoin, .dogecoin, .bitcoincash] {
            try await db.saveAsset(.init(id: chain.id + ":native", networkID: chain.id, reference: "native",
                name: chain.name, symbol: "TEST", decimals: 8))
            let snapshot = try await db.snapshot(walletID: "payment-" + chain.id, currency: "USD")
            let holding = snapshot.holdings.first { $0.reference == "native" }!
            let request = OathScannedRecipient(original: otherAddresses[chain]!, networks: [chain], amount: "1", message: "Invoice note")
            let composer = OathSendModel(walletID: snapshot.wallet.id, preferences: defaults)
            composer.choose(holding, from: snapshot, scannedRecipient: request)
            let message = "A public message with enough words to truncate inside the amount capsule."
            composer.onChainMessage = message
            check(composer.bitcoinOptionsValid && composer.recipientDetails.count == 2,
                  "Bitcoin-family message and local request note have separate capsules")
            check(composer.recipientDetails.first?.kind == .onChainMessage && composer.recipientDetails.first?.value == message,
                  "Bitcoin-family full message is retained, not shortened in the model")
            check(composer.recipientDetails.first?.isEditable == true && composer.recipientDetails.last?.isEditable == false,
                  "Only the public message opens the existing message editor")
            composer.onChainMessage = "Updated"
            check(composer.recipientDetails.first?.value == "Updated" && composer.amount == "1",
                  "Message editing preserves the selected amount")
            composer.onChainMessage = ""
            check(composer.recipientDetails.count == 1 && composer.recipientDetails.first?.kind == .paymentNote,
                  "Clearing a public message keeps the local request note")
        }
        // Binance-bridged USDT uses 18 decimals, not the six-decimal scale
        // used by USDT on several other networks. Catalog alias is BSC-USD.
        let bnbID = "payment-bnb", bnbUSDT = "0x55d398326f99059ff775485246999027b3197955"
        try await db.trackAsset(.init(id: "bnb:" + bnbUSDT, networkID: "bnb", reference: bnbUSDT,
            name: "Binance Bridged USDT", symbol: "BSC-USD", decimals: 18), walletID: bnbID)
        let bnbSnapshot = try await db.snapshot(walletID: bnbID, currency: "USD")
        let bnbToken = bnbSnapshot.holdings.first { $0.reference == bnbUSDT }!
        for uri in ["usdt:\(evm)?amount=200", "ethereum:\(bnbUSDT)@56/transfer?address=\(evm)&uint256=2e20"] {
            guard case .recipient(let request) = paymentParser.parse(uri) else { preconditionFailure("BNB USDT payment") }
            let model = OathSendModel(walletID: bnbID, scannedRecipient: request, preferences: defaults)
            model.prepareInitialSelection(from: bnbSnapshot)
            model.choose(bnbToken, from: bnbSnapshot, scannedRecipient: request)
            check(model.address == evm && model.amount == "200" && !model.fiatEntry, "BNB USDT must prefill 200 token units")
            check(try model.atomic(locale: Locale(identifier: "en_US_POSIX")) == "200000000000000000000", "BNB USDT must retain its real 18-decimal scale")
            let before = model.amount
            var invalid = request; invalid.amount = "0.0000000000000000001"; invalid.amountIsAtomic = false
            check(!model.receiveScan(invalid, chain: .bnb) && model.amount == before, "Excess precision must not partially overwrite draft")
            var zero = request; zero.amount = "0"; zero.amountIsAtomic = false
            check(model.receiveScan(zero, chain: .bnb) && model.amount == "0", "Zero request remains editable")
            check((try? model.atomic(locale: Locale(identifier: "en_US_POSIX"))) == nil, "Zero request cannot be sent")
        }
        guard case .recipient(let legacy) = paymentParser.parse("ethereum:" + evm + "?amount=50&message=Invoice%2050") else { preconditionFailure("Legacy exchange QR") }
        let legacyModel = OathSendModel(walletID: bnbID, scannedRecipient: legacy, preferences: defaults)
        legacyModel.prepareInitialSelection(from: bnbSnapshot)
        check(legacyModel.path.isEmpty && legacyModel.holding == nil, "Ambiguous exchange request must retain asset selection")
        legacyModel.choose(bnbToken, from: bnbSnapshot, scannedRecipient: legacy)
        check(legacyModel.amount == "50" && legacyModel.paymentNote == "Invoice 50", "Legacy invoice amount and note lost")
        check(try legacyModel.atomic(locale: Locale(identifier: "en_US_POSIX")) == "50000000000000000000", "Legacy BSC USDT amount wrong")
        legacyModel.address = ""
        check(legacyModel.paymentNote == nil, "Old invoice note remained on changed recipient")
        let solanaReference = try SolanaSendCrypto.address(privateKey: Data(repeating: 87, count: 32))
        guard case .recipient(let solanaPay) = paymentParser.parse("solana:" + addresses[.solana]! + "?amount=1&reference=" + solanaReference + "&memo=Order123") else { preconditionFailure("Solana Pay references") }
        let solanaSnapshot = try await db.snapshot(walletID: "payment-solana", currency: "USD")
        let solanaComposer = OathSendModel(walletID: "payment-solana", preferences: defaults)
        solanaComposer.choose(solanaSnapshot.holdings.first { $0.reference == "native" }!, from: solanaSnapshot, scannedRecipient: solanaPay)
        check(solanaComposer.solanaReferences == [solanaReference] && solanaComposer.memo == "Order123", "Solana Pay routing fields lost in composer")
        solanaComposer.address = ""
        check(solanaComposer.solanaReferences.isEmpty, "Changed recipient retained merchant references")
        let singleID = "direct-ethereumprivateKey"
        try await db.trackAsset(.init(id: "ethereum:0x4444444444444444444444444444444444444444", networkID: "ethereum",
            reference: "0x4444444444444444444444444444444444444444", name: "Fixture", symbol: "FIX", decimals: 6), walletID: singleID)
        let tokenSnapshot = try await db.snapshot(walletID: singleID, currency: "USD")
        let tokenChoice = OathSendModel(walletID: singleID, preferences: defaults)
        tokenChoice.prepareInitialSelection(from: tokenSnapshot)
        check(tokenChoice.path.isEmpty && tokenChoice.holding == nil, "Tokens remain selectable rather than silently sending native coin")
        let token = tokenSnapshot.holdings.first { $0.reference != "native" }!
        let explicit = OathSendModel(walletID: singleID, holdingID: token.id, preferences: defaults)
        explicit.prepareInitialSelection(from: tokenSnapshot)
        check(explicit.holding?.id == token.id && explicit.path == [.recipient], "Asset-detail selection wins over automatic routing")
        let tokenRecipient = "0x1111111111111111111111111111111111111111"
        let scan = OathScannedRecipient(original: tokenRecipient, networks: [.ethereum], amount: "2", amountIsAtomic: false, token: token.reference)
        let scanned = OathSendModel(walletID: singleID, scannedRecipient: scan, preferences: defaults)
        scanned.prepareInitialSelection(from: tokenSnapshot)
        check(scanned.path == [.amount] && scanned.holding?.id == token.id, "Exact token scan opens amount directly")
        scanned.choose(token, from: tokenSnapshot, scannedRecipient: scan)
        check(scanned.holding?.id == token.id && scanned.address == tokenRecipient && scanned.amount == "2", "Selecting the scanned asset preserves recipient and amount")
        guard case .recipient(let noAmount) = paymentParser.parse("ethereum:" + tokenRecipient + "@1") else { preconditionFailure("Native donation") }
        let donation = OathSendModel(walletID: singleID, scannedRecipient: noAmount, preferences: defaults)
        donation.prepareInitialSelection(from: tokenSnapshot)
        check(donation.path == [.amount] && donation.amount.isEmpty && donation.holding?.reference == "native", "Explicit native request without amount goes directly to amount entry")

        let unsavedReference = "0x5555555555555555555555555555555555555555"
        let unsavedScan = OathScannedRecipient(original: tokenRecipient, networks: [.ethereum], amount: "2500000", amountIsAtomic: true, token: unsavedReference)
        let scanPreview = Holding.catalogPreview(account: tokenSnapshot.accounts[0], address: tokenSnapshot.accounts[0].address,
            assetID: "ethereum:" + unsavedReference, reference: unsavedReference, name: "Fixture", symbol: "TEST", logo: nil)
        func unresolved() -> OathSendModel {
            let result = OathSendModel(walletID: singleID, scannedRecipient: unsavedScan, preferences: defaults)
            result.prepareInitialSelection(from: tokenSnapshot)
            check(result.scannedAssetResolution != nil && result.path.isEmpty, "Unsaved exact contract schedules one resolution")
            return result
        }
        let resolved = unresolved()
        await resolved.resolveScannedAsset { _, _ in (scanPreview, tokenSnapshot) }
        check(resolved.path == [.amount] && resolved.amount.isEmpty && resolved.holding?.isCatalogPreview == true,
            "Resolved identity opens amount while waiting for verified decimals")
        check(!resolved.prepareReview(locale: Locale(identifier: "en_US")), "Metadata scanPreview cannot be sent")
        let resolvedObservation = Task { await resolved.observe(currency: "USD") }
        try await db.trackAsset(.init(id: scanPreview.assetID, networkID: "ethereum", reference: unsavedReference,
            name: "Fixture", symbol: "TEST", decimals: 6), walletID: singleID)
        for _ in 0..<200 where resolved.holding?.isCatalogPreview == true { try await Task.sleep(for: .milliseconds(10)) }
        check(resolved.path == [.amount] && resolved.amount == "2.5" && resolved.holding?.isCatalogPreview == false,
            "Deferred metadata applies exact atomic amount without losing the route")
        resolvedObservation.cancel(); await resolvedObservation.value
        for action in 0..<5 {
            let stale = unresolved()
            await stale.resolveScannedAsset { _, _ in
                switch action {
                case 0: stale.choose(token, from: tokenSnapshot)
                case 1: stale.query = "manual search"
                case 2: stale.selectWallet("two")
                case 3: return nil
                default: return (arcNative, arcSnapshot)
                }
                return (scanPreview, tokenSnapshot)
            }
            check(stale.holding?.id != scanPreview.id && !stale.path.contains(.amount), "Late/failed/mismatched scan resolution cannot replace user intent")
        }
        try await db.importWalletIfNeeded(.init(id: "ambiguous-sender", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1), accounts: [
            .init(id: "sender-a", walletID: "ambiguous-sender", networkID: "ethereum", address: evm, derivationPath: "fixture-a"),
            .init(id: "sender-b", walletID: "ambiguous-sender", networkID: "ethereum", address: otherAddresses[.ethereum]!, derivationPath: "fixture-b")
        ])
        let ambiguousSnapshot = try await db.snapshot(walletID: "ambiguous-sender", currency: "USD")
        for payment in [noAmount, unsavedScan] {
            let ambiguous = OathSendModel(walletID: ambiguousSnapshot.wallet.id, scannedRecipient: payment, preferences: defaults)
            ambiguous.prepareInitialSelection(from: ambiguousSnapshot)
            check(ambiguous.path.isEmpty && ambiguous.scannedAssetResolution == nil && ambiguous.holding == nil,
                  "Multiple sender accounts must retain explicit selection")
        }
        let cancelled = unresolved()
        let cancellation = Task {
            await cancelled.resolveScannedAsset { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return (scanPreview, tokenSnapshot)
            }
        }
        await cancellation.value
        check(cancelled.holding == nil && cancelled.path.isEmpty, "Cancelled lookup cannot navigate")
        let delayed = OathSendModel(walletID: "direct-bitcoinprivateKey", preferences: defaults)
        let delayedObservation = Task { await delayed.observe(currency: "USD") }
        for _ in 0..<200 where delayed.loading { try await Task.sleep(for: .milliseconds(10)) }
        check(delayed.path == [.recipient], "A cold database observation also resolves the direct route")
        delayedObservation.cancel(); await delayedObservation.value
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
        let previewSnapshot = model.snapshot!
        check(model.path.isEmpty && model.holding == nil, "Multiple networks retain explicit asset selection")
        // Opening a saved address uses its explicit network, even when the
        // identical address is stored on another EVM network.
        let contactAddress = "0x3333333333333333333333333333333333333333"
        let savedContact = try await db.saveContact(id: UUID().uuidString, name: "Send fixture", addresses: [
            .init(networkID: "polygon", address: contactAddress, label: "Polygon"),
            .init(networkID: "base", address: contactAddress, label: "Base")
        ])
        let savedRecipient = SendRecipient(address: savedContact.addresses[0], contactName: savedContact.contact.name)
        let contactModel = OathSendModel(walletID: "one", recipient: savedRecipient, preferences: defaults)
        let contactObservation = Task { await contactModel.observe(currency: "USD") }
        defer { contactObservation.cancel() }
        for _ in 0..<200 where contactModel.loading { try await Task.sleep(for: .milliseconds(10)) }
        check(!contactModel.loading && !contactModel.holdings.isEmpty, "Contact picker observes wallet holdings")
        check(contactModel.recipientNetworks == Set([.polygon]), "Catalog search is limited to the saved network")
        check(contactModel.holdings.allSatisfy { $0.networkID == "polygon" },
              "Identical EVM addresses do not broaden the asset picker to other networks")
        let polygonNative = contactModel.holdings.first { $0.reference == "native" }!
        contactModel.choose(polygonNative)
        check(contactModel.path == [.amount] && contactModel.address == contactAddress
            && contactModel.recipientName == savedContact.contact.name,
              "A saved address opens amount directly with the contact recipient intact")
        contactModel.choose(previewSnapshot.holdings.first { $0.networkID == "base" }!, from: previewSnapshot)
        check(contactModel.path == [.amount] && contactModel.holding?.id == polygonNative.id,
              "A mismatched network selection cannot replace the contact draft")
        contactModel.path = []
        contactModel.choose(polygonNative)
        check(contactModel.path == [.amount], "Back to the picker and reselect still skips recipient entry")

        let polygonAccount = previewSnapshot.accounts.first { $0.networkID == "polygon" }!
        let contactToken = Holding.catalogPreview(account: polygonAccount, address: polygonAccount.address,
            assetID: "polygon:0x4444444444444444444444444444444444444444",
            reference: "0x4444444444444444444444444444444444444444",
            name: "Contact catalog fixture", symbol: "FIXTURE", logo: nil)
        contactModel.choose(contactToken, from: previewSnapshot)
        check(contactModel.path == [.amount] && contactModel.address == contactAddress,
              "Contact catalog results also navigate immediately to amount")
        contactModel.enter(.digit(1), locale: Locale(identifier: "en_US"))
        check(contactModel.amount.isEmpty && !contactModel.prepareReview(locale: Locale(identifier: "en_US")),
              "Skipping recipient entry does not allow unresolved token metadata into a transaction")
        try await db.trackAsset(.init(id: contactToken.assetID, networkID: "polygon", reference: contactToken.reference,
            name: contactToken.name, symbol: contactToken.symbol, decimals: 6), walletID: "one")
        for _ in 0..<200 where contactModel.holding?.isCatalogPreview == true {
            try await Task.sleep(for: .milliseconds(10))
        }
        check(contactModel.holding?.isCatalogPreview == false && contactModel.path == [.amount]
            && contactModel.address == contactAddress,
              "Background token resolution preserves the direct amount route and recipient")

        for (recipientAddress, invalid) in [("invalid-address", true), (evm, false)] {
            let record = try await db.saveContact(id: UUID().uuidString, name: "Validation fixture", addresses: [
                .init(networkID: "polygon", address: recipientAddress)
            ])
            let guarded = OathSendModel(walletID: "one", recipient:
                SendRecipient(address: record.addresses[0], contactName: record.contact.name), preferences: defaults)
            guarded.choose(polygonNative, from: previewSnapshot)
            check(guarded.path == [.recipient] && !guarded.validateRecipient(),
                  "Invalid or self-send saved addresses must still pass the normal recipient rules")
            check(invalid ? guarded.addressError : guarded.selfTransferRestriction != nil,
                  "The recipient form retains the reason a saved address could not advance")
        }
        let previewAccount = previewSnapshot.accounts.first { $0.networkID == "ethereum" }!
        let previewReference = "0x2222222222222222222222222222222222222222"
        let preview = Holding.catalogPreview(account: previewAccount, address: previewAccount.address,
            assetID: "ethereum:" + previewReference, reference: previewReference,
            name: "Catalog fixture", symbol: "TEST", logo: nil)
        model.choose(preview, from: previewSnapshot)
        model.address = "0x3333333333333333333333333333333333333333"
        check(model.path == [.recipient] && model.holding?.isCatalogPreview == true,
              "Catalog tokens open recipient entry without waiting for metadata or persistence")
        model.enter(.digit(1), locale: Locale(identifier: "en_US"))
        check(model.amount.isEmpty && (try? model.atomic(locale: Locale(identifier: "en_US"))) == nil,
              "Display-only catalog scales cannot become transaction amounts")
        check(!model.prepareReview(locale: Locale(identifier: "en_US")), "Catalog preview cannot reach signing review")
        let pendingPayment = OathScannedRecipient(original: model.address, networks: [.ethereum],
            amount: "1234500", amountIsAtomic: true, token: previewReference)
        check(model.receiveScan(pendingPayment, chain: .ethereum) && model.amount.isEmpty,
              "Scanned atomic amounts wait for real metadata without blocking recipient navigation")
        try await db.trackAsset(.init(id: preview.assetID, networkID: "ethereum", reference: previewReference,
            name: preview.name, symbol: preview.symbol, decimals: 6), walletID: "one")
        for _ in 0..<200 where model.holding?.isCatalogPreview == true { try await Task.sleep(for: .milliseconds(10)) }
        check(model.holding?.isCatalogPreview == false && model.holding?.decimals == 6,
              "The ordinary observer promotes the preview to resolved metadata")
        check(model.address == "0x3333333333333333333333333333333333333333" && model.path == [.recipient],
              "Background tracking preserves recipient entry and does not navigate again")
        check(model.amount == "1.2345", "Deferred scanned amounts use the resolved six-decimal scale")
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
        for chain in [OathImportChain.chiliz, .filecoin, .sei, .zerog, .iotex] {
            let holding = model.holdings.first { $0.networkID == chain.id && $0.reference == "native" }!
            model.choose(holding)
            let owner = addresses[chain]!
            let alias = chain == .filecoin ? try FilecoinIdentity.delegated(owner)
                : chain == .iotex ? try IoTeXIdentity.native(owner).uppercased() : owner.lowercased()
            let request = OathScannedRecipient(original: alias, networks: [chain], amount: "1")
            check(model.receiveScan(request, chain: chain), "Self-address QR remains a valid address: " + chain.id)
            check(model.selfTransferRestriction == .wallet && !model.validateRecipient(),
                  "QR self-send is blocked before amount/review: " + chain.id)
            let contact = try await db.saveContact(id: UUID().uuidString, name: "Self alias", addresses: [.init(networkID: chain.id, address: alias)])
            model.setRecipient(SendRecipient(address: contact.addresses[0], contactName: contact.contact.name))
            check(model.selfTransferRestriction == .wallet && !model.validateRecipient(),
                  "Contact self-send is blocked before amount/review: " + chain.id)
            model.address = "0x" + String(repeating: "3", count: 40)
            check(model.selfTransferRestriction == nil && model.validateRecipient(),
                  "A different recipient remains available: " + chain.id)
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
