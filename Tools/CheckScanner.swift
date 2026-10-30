import Foundation
import Vision
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import OathAnkr
import OathBitcoin

/// Deliberately fixed failure messages: neither mnemonic nor scan payload is printed.
@main struct CheckScanner {
    struct MessageVector: Decodable { let message: String; let address: String; let digest: String; let signature: String }
    struct Vector: Decodable { let mnemonic: String }
    enum Failure: Error { case assertion(String), qr }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let resources = root.appendingPathComponent("OathApp/Resources/BIP39")
        let validator = try OathMnemonicValidator.load { resources.appendingPathComponent($0 + "." + $1) }
        let networkIDs = Dictionary(uniqueKeysWithValues: OathTokenNetwork.all.filter { $0.chain.isEVM }.compactMap { row in row.chainID.map { ($0, row.chain) } })
        let parser = OathScanParser(validator: validator, evmNetworks: networkIDs)
        var checks = 0, qrCount = 0, vectorCount = 0
        func check(_ value: Bool, _ reason: String) throws { guard value else { throw Failure.assertion(reason) }; checks += 1 }
        try check(OathWalletConnectPolicy.requiresFreshPairing(NSError(domain: "WalletConnectPairing.WalletPairService.Errors", code: 0)), "Consumed pairing requires a new QR")
        try check(!OathWalletConnectPolicy.requiresFreshPairing(NSError(domain: "WalletConnectPairing.WalletPairService.Errors", code: 1)), "Disconnected relay remains retryable")
        try check(!OathWalletConnectPolicy.requiresFreshPairing(NSError(domain: "OtherProvider", code: 0)), "Unrelated errors remain retryable")
        func qr(_ payload: String) throws -> String {
            guard let image = OathReceiveQRCode.image(for: payload) else { throw Failure.qr }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw Failure.qr }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination), let decoded = try OathScanImage.codes(in: data as Data).first,
                  decoded == payload else { throw Failure.qr }
            qrCount += 1; return decoded
        }
        func recipient(_ payload: String) -> OathScannedRecipient? {
            if case .recipient(let value) = parser.parse(payload) { return value }; return nil
        }
        let delegatedFIL = "f410fe7xvzw7ac535mjbyv77lnfpdh7bdgwlzqbe3qsy"
        let decodedFIL = recipient(try qr(delegatedFIL))
        try check(decodedFIL?.networks == [.filecoin], "Filecoin delegated QR network")
        try check(decodedFIL?.decoded(on: .filecoin)?.address == "0x27ef5cdbe01777d62438affeb695e33fc2335979", "Filecoin delegated QR identity")
        let filPayment = recipient(try qr("ethereum:0x27ef5cdbe01777d62438affeb695e33fc2335979@314?value=1e18"))
        try check(filPayment?.networks == [.filecoin] && filPayment?.amount == "1000000000000000000", "Filecoin chain ID payment QR")
        struct AezeedVector: Decodable { let phrase: String }
        let aezeedURL = root.appendingPathComponent("Packages/OathAezeed/Tests/OathAezeedTests/Fixtures/lnd-production.json")
        for vector in try JSONDecoder().decode([AezeedVector].self, from: Data(contentsOf: aezeedURL)) {
            guard case .recovery(let phrase) = parser.parse(try qr(vector.phrase)) else {
                throw Failure.assertion("aezeed QR must enter recovery import")
            }
            try check(phrase.phrase == vector.phrase && phrase.aezeed == nil,
                      "QR recognition must preserve words without claiming passphrase authentication")
        }
        let electrumURL = root.appendingPathComponent("Packages/OathBitcoin/Tests/OathBitcoinTests/Fixtures/electrum-reference.json")
        for vector in try JSONDecoder().decode([AezeedVector].self, from: Data(contentsOf: electrumURL)) {
            guard case .recovery(let phrase) = parser.parse(try qr(vector.phrase)) else {
                throw Failure.assertion("Electrum QR must enter recovery import")
            }
            try check(phrase.phrase == vector.phrase && phrase.electrum == nil, "Electrum QR must defer seed extension and format choice to import")
        }
        func invalid(_ payload: String) -> Bool { if case .invalid = parser.parse(payload) { return true }; return false }
        // Public scalar 1 and deterministic public Ed25519 test seed, never funded or imported.
        let scalar = Data(repeating: 0, count: 31) + Data([1]), ed = Data(0..<32)
        var addresses: [(OathImportChain, String)] = []
        for chain in OathImportChain.allCases.filter(\.isEVM) {
            addresses.append((chain, "0x52908400098527886E0F7030069857D2E4169EE7"))
        }
        let descriptors: [(OathImportChain, BitcoinWalletDescriptor)] = [
            (.bitcoin, try BitcoinKeys.singleKey(bytes: scalar, compressed: true)),
            (.litecoin, try LitecoinKeys.singleKey(bytes: scalar, compressed: true)),
            (.bitcoincash, try BitcoinCashKeys.singleKey(bytes: scalar, compressed: true)),
            (.dogecoin, try DogecoinKeys.singleKey(bytes: scalar, compressed: true))]
        for (chain, descriptor) in descriptors {
            for branch in descriptor.branches where branch.change == 0 {
                for value in try BitcoinKeys.addresses(branch: branch, range: 0..<1) { addresses.append((chain, value.address)) }
            }
        }
        addresses += [(.bitcoin, "1LqBGSKuX5yYUonjxT5qGfpUsXKYYWeabA"),
            (.bitcoin, "37VucYSaXLCAsxYyAPfbSi9eh4iEcbShgf"),
            (.bitcoin, "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"),
            (.bitcoin, "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr"),
            (.bitcoincash, "bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a"),
            (.bitcoincash, "1BpEi6DfDAUFd7GtittLSdBeYJvcoaVggu"),
            (.polkadot, try PolkadotIdentity.address(publicKey: ed)), (.near, "scanner.near"), (.near, String(repeating: "ab", count: 32)),
            (.thorchain, "thor1gm00vwsfcp48enm4uv9e5dhm37jtd0ye27wrx0"),
            (.solana, try SolanaSendCrypto.address(privateKey: ed)), (.tron, try TronSendCrypto.address(privateKey: scalar)),
            (.sui, try SuiSendCrypto.address(privateKey: ed)), (.aptos, try AptosSendCrypto.address(privateKey: ed)),
            (.sui, "0x1"), (.aptos, "0x1"),
            (.xrpl, try XrplSendCrypto.address(privateKey: scalar)), (.stellar, try StellarSendCrypto.address(privateKey: ed))]
        let ton = try TonSendCrypto.address(publicKey: TonSendCrypto.publicKey(privateKey: ed))
        addresses += [(.ton, ton), (.ton, try TonIdentity.friendly(ton)), (.ton, try TonIdentity.friendly(ton, bounceable: false))]
        var covered = Set<OathImportChain>()
        for (chain, address) in addresses {
            let scanned = try qr(address)
            try check(recipient(scanned)?.networks.contains(chain) == true, "Supported address rejected: " + chain.rawValue)
            try check(recipient(scanned)?.decoded(on: chain) != nil, "Recipient conversion failed: " + chain.rawValue)
            guard let appLink = OathWalletLink.paymentURL(address: address, chain: chain),
                  case .payment(let linked) = OathWalletLink.parse(appLink) else {
                throw Failure.assertion("Oath payment link unavailable: " + chain.rawValue)
            }
            try check(linked.networks == [chain], "Oath link must retain the chosen network")
            try check(linked.decoded(on: chain) == recipient(address)?.decoded(on: chain), "Oath link changed the recipient")
            try check(recipient(try qr(appLink.absoluteString)) == linked, "Oath QR must use the same parser as external links")
            var plain = address
            if chain == .bitcoincash, plain.hasPrefix("bitcoincash:") { plain = String(plain.dropFirst(12)) }
            let payment: String
            if chain.isEVM {
                let id = networkIDs.first(where: { $0.value == chain })!.key
                payment = "ethereum:\(plain)@\(id)?value=1000000000000000"
            } else if chain == .ton { payment = "ton:transfer/\(plain)?amount=1000" }
            else { payment = "\(chain.rawValue):\(plain)?amount=0.001" }
            guard let url = URL(string: try qr(payment)), case .payment(let external) = OathWalletLink.parse(url) else {
                throw Failure.assertion("External chain payment rejected: " + chain.rawValue)
            }
            let separator = payment.firstIndex(of: ":")!
            let uppercaseScheme = payment[..<separator].uppercased() + payment[separator...]
            try check(recipient(uppercaseScheme) == external, "Uppercase payment scheme changed routing: " + chain.id)
            try check(external == recipient(payment), "Camera and in-app payment parsing differ")
            try check(external.networks == [chain] && external.amount != nil, "External payment lost network or amount")
            let nativeContext = OathScannerContext.asset(chain, reference: "native", symbol: chain.id.uppercased())
            try check(nativeContext.route(external) == .recipient(chain), "Matching native request bypasses picker: " + chain.id)
            try check(nativeContext.route(recipient(scanned)!) == .recipient(chain), "Bare address retains selected network: " + chain.id)
            try check(nativeContext.accepts(.recipient(external)), "Asset scanner accepts payment requests")
            try check(!nativeContext.accepts(.walletConnect("fixture")) && !nativeContext.accepts(.privateKey("fixture")),
                      "Asset scanner cannot start an unrelated connection or import")
            for other in OathImportChain.allCases where other != chain {
                try check(OathScannerContext.asset(other, reference: "native", symbol: other.id.uppercased()).route(external) == .review,
                          "Explicit different network requires confirmation: " + other.id)
            }
            if chain.supportsTokens {
                let tokenReference = chain == .ton ? ton : "fixture-token"
                let tokenContext = OathScannerContext.asset(chain, reference: tokenReference, symbol: "TEST")
                try check(tokenContext.route(external) == .review, "Native amount cannot silently become a token amount")
                try check(tokenContext.route(recipient(scanned)!) == .recipient(chain), "Bare address preserves selected token")
                var tokenRequest = external
                tokenRequest.token = tokenReference
                try check(tokenContext.route(tokenRequest) == .recipient(chain), "Matching token request advances")
                tokenRequest.token = "another-token"
                try check(tokenContext.route(tokenRequest) == .review, "Different token requires confirmation")
            }
            covered.insert(chain)
        }
        try check(covered == Set(OathImportChain.allCases), "Chain catalog coverage incomplete")
        for (chain, address) in addresses {
            guard let invoice = recipient(try qr(address + "?amount=50.125&label=Shop&message=Invoice%2042")) else {
                throw Failure.assertion("Schemeless payment QR rejected: " + chain.id)
            }
            try check(invoice.networks.contains(chain) && invoice.amount == "50.125" && !invoice.amountIsAtomic,
                      "Schemeless amount or compatible network lost: " + chain.id)
            if chain == .bitcoincash, let decoded = invoice.decoded(on: chain) {
                try check(BitcoinSendPlan.recipientScript(decoded.address, chain: .bitcoincash) == BitcoinSendPlan.recipientScript(address, chain: .bitcoincash), "CashAddr payment changed its destination")
            } else {
                try check(invoice.decoded(on: chain) == recipient(address)?.decoded(on: chain), "Schemeless address changed")
            }
            try check(invoice.displayNote == "Shop\nInvoice 42", "Schemeless notes lost")
            try check(OathScannerContext.asset(chain, reference: "native", symbol: "NATIVE").route(invoice) == .recipient(chain),
                      "Selected native asset must supply context for schemeless amount")
            if chain.supportsTokens {
                try check(!invoice.hasExactAsset && invoice.amountAssetUnspecified, "Schemeless QR invented an asset")
                try check(OathScannerContext.asset(chain, reference: "test-token", symbol: "TOKEN").route(invoice) == .recipient(chain),
                          "Schemeless quantity must apply to the explicitly selected token")
            }
            for suffix in ["?amount=-1", "?amount=NaN", "?amount=1e18", "?amount=1&amount=2", "?amount=1&chain=unknown", "?amount=1#ignored", "?req-unknown=1", "?amount=1&value=1", "?amount=1&exp=1"] {
                try check(invalid(address + suffix), "Ambiguous/invalid schemeless instruction accepted: " + chain.id)
            }
        }
        let bitcoinRecipient = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"
        let taprootRecipient = "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr"
        let uppercaseBitcoin = recipient(try qr("BITCOIN:" + bitcoinRecipient.uppercased() + "?AMOUNT=0.5&LABEL=Shop&MESSAGE=Invoice"))
        try check(uppercaseBitcoin?.amount == "0.5" && uppercaseBitcoin?.displayNote == "Shop\nInvoice" && uppercaseBitcoin?.hasExactAsset == true,
                  "BIP321 uppercase fields lost")
        let alternatives = recipient(try qr("bitcoin:?bc=" + bitcoinRecipient + "&bc=" + taprootRecipient + "&amount=0.125"))
        try check(alternatives?.original == bitcoinRecipient && alternatives?.amount == "0.125", "BIP321 on-chain alternatives lost")
        let fallback = recipient("bitcoin:" + bitcoinRecipient + "?amount=0.125&lightning=" + String(repeating: "a", count: 1200) + "&extension=one&extension=two")
        try check(fallback?.original == bitcoinRecipient && fallback?.amount == "0.125", "BIP321 optional instructions broke on-chain fallback")
        for suffix in ["?amount=1&AMOUNT=2", "?LABEL=a&label=b", "?REQ-UNKNOWN=1", "?REQ-POP=callback%3A", "?bc=invalid"] {
            try check(invalid("bitcoin:" + bitcoinRecipient + suffix), "BIP321 ambiguous or required instructions accepted")
        }
        try check(invalid("bitcoin:?lightning=lnbc1unsupported"), "Lightning-only QR must not become an on-chain payment")
        try check(invalid("bitcoin:?bc=&amount=1"), "Empty BIP321 alternative accepted")
        let arcInvoice = "0x3333333333333333333333333333333333333333?amount=50"
        let arcRequest = recipient(try qr(arcInvoice))
        try check(arcRequest?.networks.contains(.arc) == true && arcRequest?.amount == "50" && arcRequest?.amountAssetUnspecified == true,
                  "Reported Arc invoice must preserve fifty units without guessing network or token")
        if let fixture = ProcessInfo.processInfo.environment["OATH_ARC_PAYMENT_QR_FIXTURE"] {
            let codes = try OathScanImage.codes(in: Data(contentsOf: URL(fileURLWithPath: fixture)))
            try check(codes.count == 1, "Actual invoice screenshot must contain one payment QR")
            let invoice = recipient(codes[0])
            try check(invoice?.amount == "50" && invoice?.amountAssetUnspecified == true && invoice?.networks.contains(.arc) == true,
                      "Actual Arc screenshot must preserve amount and unresolved network")
            try check(invoice?.decoded(on: .arc)?.address == codes[0].components(separatedBy: "?").first,
                      "Actual screenshot destination must remain unchanged")
        }
        for (id, chain) in networkIDs {
            let donation = recipient("ethereum:\(addresses[0].1)@\(id)")
            try check(donation?.hasExactAsset == true && donation?.token == "native" && donation?.amount == nil,
                      "Network-qualified native request without amount must retain asset identity: " + chain.id)
        }
        for prefix in ["gram:transfer/", "GRAM://transfer/", "TON://transfer/"] {
            let payment = recipient(try qr(prefix + ton + "?amount=1000000000&text=Invoice"))
            try check(payment?.amount == "1000000000" && payment?.amountIsAtomic == true && payment?.networks == [.ton] && payment?.memo == "Invoice",
                      "TON alias changed atomic amount or comment")
        }
        let thor="thor1gm00vwsfcp48enm4uv9e5dhm37jtd0ye27wrx0"
        try check(recipient(try qr(thor))?.networks == [.thorchain], "THORChain QR incorrectly offered another network")
        try check(recipient(try qr("thorchain:"+thor))?.networks == [.thorchain], "THORChain URI lost its network")
        try check(OathScanAddress.decode(String(thor.dropLast())+"q",chain:.thorchain) == nil, "THORChain checksum was ignored")
        // Assert the complete candidate set, not just inclusion: NEAR's permissive
        // named-account grammar must not add a second network to a Bitcoin scan.
        let segwit = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"
        let taproot = "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr"
        for address in [segwit, segwit.uppercased(), taproot, taproot.uppercased()] {
            let result = recipient(try qr(address))
            try check(result?.networks == [.bitcoin], "Bitcoin QR incorrectly offered another network")
            try check(result?.decoded(on: .near) == nil, "Bitcoin QR could route to NEAR")
        }
        for (chain, address) in addresses where UTXONetwork(rawValue: chain.rawValue) != nil {
            try check(recipient(address)?.networks.contains(.near) == false, "UTXO address misidentified as a NEAR name")
        }
        let cashaddr = "qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a"
        try check(recipient(try qr(cashaddr))?.networks == [.bitcoincash], "Prefixless CashAddr misidentified")
        for (_, address) in addresses where address.hasPrefix("ltc1") {
            try check(recipient(try qr(address))?.networks == [.litecoin], "Litecoin SegWit misidentified")
        }
        let legacy = "1BpEi6DfDAUFd7GtittLSdBeYJvcoaVggu"
        try check(Set(recipient(legacy)?.networks ?? []) == [.bitcoin, .bitcoincash], "Real BTC/BCH legacy overlap lost")
        for account in ["scanner.near", "sub.scanner.near", "root", "my-account_1", String(repeating: "ab", count: 32), "0s" + String(repeating: "ab", count: 20)] {
            try check(recipient(try qr(account))?.networks == [.near], "Genuine NEAR account rejected")
        }
        // NEAR really supports lowercase Ethereum-like implicit accounts. Preserve
        // that overlap; only the broad named-account fallback has lower priority.
        let ethImplicit = "0x" + String(repeating: "ab", count: 20)
        let implicitNetworks = Set(recipient(ethImplicit)?.networks ?? [])
        try check(implicitNetworks == Set(OathImportChain.allCases.filter(\.isEVM) + [.near, .sui, .aptos, .tron]), "NEAR Ethereum-like overlap lost")
        try check(Set(recipient("0x1")?.networks ?? []) == [.sui, .aptos], "Short Move address misidentified as a NEAR name")
        // An explicit NEAR request can still name an account that happens to look
        // like another chain's address. Detection must not change NEAR validation.
        try check(OathScanAddress.decode(segwit, chain: .near) != nil, "NEAR account validation was overrestricted")
        try check(recipient(try qr("near:" + segwit))?.networks == [.near], "Explicit NEAR request lost its network")
        try check(recipient(try qr("bitcoin:" + segwit))?.networks == [.bitcoin], "Explicit Bitcoin request lost its network")
        // Exercise production routing and asset filtering across the complete
        // address matrix, independent of the scanner's camera/SwiftUI lifecycle.
        for (_, address) in addresses {
            guard let result = recipient(address) else { throw Failure.assertion("Missing scan recipient") }
            try check(OathScannerContext.home.route(result) == .assets, "Home address scan did not open asset selection")
            for chain in OathImportChain.allCases {
                let compatible = result.networks.contains(chain)
                try check(result.matchesAsset(networkID: chain.id, reference: "native") == compatible, "Native asset filter disagrees with scan network")
                try check(result.matchesAsset(networkID: chain.id, reference: "test-token") == compatible, "Token asset filter disagrees with scan network")
                try check(OathScannerContext.recipient(chain).route(result) == (compatible ? .recipient(chain) : .review), "Selected send network was switched or ignored")
            }
            try check(!result.matchesAsset(networkID: "unknown", reference: "native"), "Unknown network accepted")
            try check(OathScannerContext.recovery.route(result) == .review && OathScannerContext.privateKey.route(result) == .review, "Address bypassed import consent")
        }
        let bitcoinScan = recipient(segwit)!
        try check(OathScannerContext.contact(.bitcoin).route(bitcoinScan) == .contact(.bitcoin), "Bitcoin contact scan did not return the address")
        try check(OathScannerContext.contact(.near).route(bitcoinScan) == .review, "Contact scan changed its selected network")
        try check(OathScannerContext.contact(nil).route(bitcoinScan) == .review, "Contact without a network was guessed")
        try check(recipient(addresses[0].1)?.networks.filter(\.isEVM).count == networkIDs.count, "EVM ambiguity lost")
        try check(OathScanAddress.decode("0x52908400098527886E0F7030069857D2e4169EE7", chain: .ethereum) == nil, "EIP55 invalid checksum")
        try check(OathScanAddress.decode("tb1qdkwepttcl8729l5ngk2rnqdsa4fz9xhl3t4cl9", chain: .bitcoin) == nil, "Testnet address accepted on mainnet")
        // Muxed Stellar account and mainnet XRP X-address retain routing identifiers.
        let pub = try Curve25519.Signing.PrivateKey(rawRepresentation: ed).publicKey.rawRepresentation
        let stellar = try StellarSendCrypto.address(privateKey: ed)
        for id: UInt64 in [0, 123456, .max] {
            let encoded = OathScanAddress.strKey(pub + Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: id >> ($0 * 8)) }), version: 96)
            let result = recipient(try qr(encoded))?.decoded(on: .stellar)
            try check(result?.address == stellar && result?.memo == String(id) && result?.memoType == "id", "Muxed routing lost")
        }
        let classic = try XrplSendCrypto.address(privateKey: scalar)
        let classicBytes = OathScanAddress.base58Check(classic, alphabet: OathScanAddress.rippleAlphabet)!
        for tag: UInt32 in [0, 123456, .max] {
            let payload = Data([5, 68]) + classicBytes.dropFirst() + Data([1]) + Data((0..<4).map { UInt8(truncatingIfNeeded: tag >> ($0 * 8)) }) + Data(repeating: 0, count: 4)
            let encoded = OathScanAddress.base58Encode(payload, alphabet: OathScanAddress.rippleAlphabet)
            let result = recipient(try qr(encoded))?.decoded(on: .xrpl)
            try check(result?.address == classic && result?.memo == String(tag), "X-address routing lost")
        }
        // Independent official SEP-23 vectors, including non-canonical encodings.
        let muxed = "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVAAAAAAAAAAAAAJLK"
        try check(recipient(try qr(muxed))?.decoded(on: .stellar)?.memo == "9223372036854775808", "Official SEP23 ID mismatch")
        let muxedPayment = recipient(muxed + "?amount=2&memo=9223372036854775808")
        try check(muxedPayment?.decoded(on: .stellar)?.memoType == "id", "Schemeless payment must preserve an embedded Stellar ID memo")
        try check(invalid("web+stellar:pay?destination=" + muxed + "&memo=9223372036854775808&memo_type=MEMO_TEXT"),
                  "Explicit text memo cannot replace an embedded ID memo")
        let muxedID = recipient("web+stellar:pay?destination=" + muxed + "&memo=9223372036854775808&memo_type=MEMO_ID&amount=2")
        try check(muxedID?.decoded(on: .stellar)?.memoType == "id", "Matching SEP7 embedded ID memo rejected")
        let donationContact = recipient("bitcoin:" + bitcoinRecipient)!
        try check(OathScannerContext.contact(.bitcoin).route(donationContact) == .contact(.bitcoin),
                  "A native address URI without payment fields must remain usable as a contact")
        for bad in [muxed + "A", "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAAAAAAAACJUO"] {
            try check(OathScanAddress.decode(bad, chain: .stellar) == nil, "Noncanonical muxed address accepted")
        }
        // Actual BIP39 phrases, including all supported languages and word counts.
        var languages = Set<String>(), counts = Set<Int>()
        for file in ["BIP39Vectors", "BIP39AdditionalVectors"] {
            let vectors = try JSONDecoder().decode([String: [Vector]].self, from: Data(contentsOf: root.appendingPathComponent("Tools/Fixtures/\(file).json")))
            for (language, rows) in vectors {
                for vector in rows {
                    let scan = try qr(vector.mnemonic)
                    guard case .recovery(let phrase) = parser.parse(scan) else { throw Failure.assertion("Valid BIP39 QR rejected") }
                    try check(phrase.phrase == OathMnemonicValidator.normalize(vector.mnemonic).split(whereSeparator: \.isWhitespace).joined(separator: " "), "Phrase normalization changed words")
                    languages.insert(language); counts.insert(OathMnemonicValidator.words(in: scan).count); vectorCount += 1
                }
            }
        }
        try check(languages == Set(OathMnemonicValidator.languages) && counts == OathMnemonicValidator.wordCounts, "Mnemonic matrix incomplete")
        try check(invalid(Array(repeating: "abandon", count: 12).joined(separator: " ")), "Invalid checksum accepted")
        try check(invalid("https://example.com"), "Web URL accepted")
        try check(invalid("ethereum:"), "Empty payment target accepted")
        try check(invalid(String(repeating: "a", count: 8193)), "Oversized QR accepted")
        try check(invalid("\u{202E}" + classic), "Bidi control accepted")
        let btc = addresses.first(where: { $0.0 == .bitcoin })!.1
        let payment = "bitcoin:\(btc)?amount=0.001&label=Test"
        try check(recipient(try qr(payment))?.amount == "0.001", "BIP21 amount lost")
        let bitcoinPayment = recipient(payment)!
        try check(OathScannerContext.home.route(bitcoinPayment) == .assets, "Payment scan did not open asset selection")
        try check(bitcoinPayment.matchesAsset(networkID: "bitcoin", reference: "native"), "Native payment asset excluded")
        try check(!bitcoinPayment.matchesAsset(networkID: "bitcoin", reference: "token") && !bitcoinPayment.matchesAsset(networkID: "bitcoincash", reference: "native"), "Payment asset constraint lost")
        try check(OathScannerContext.contact(.bitcoin).route(bitcoinPayment) == .review, "Contact scan discarded payment fields")
        try check(invalid(payment + "&amount=1"), "Duplicate amount accepted")
        try check(invalid(payment + "&req-unknown=1"), "Unsupported required instruction discarded")
        try check(invalid(payment + "&exp=1"), "Expired payment accepted")
        try check(recipient("xrp:\(classic)?dt=0")?.decoded(on: .xrpl)?.memo == "0", "XRP tag zero lost")
        try check(OathScannerContext.contact(.xrpl).route(recipient("xrp:\(classic)?dt=0")!) == .review, "Contact scan discarded destination tag")
        try check(invalid("xrp:\(classic)?dt=4294967296"), "XRP overflow accepted")
        try check(recipient("web+stellar:pay?destination=\(stellar)&memo=123&memo_type=id")?.decoded(on: .stellar)?.memoType == "id", "Stellar memo type lost")
        let hash = Data(repeating: 7, count: 32).base64EncodedString()
        let hashResult = recipient("web+stellar:pay?destination=\(stellar)&memo=\(hash)&memo_type=return")
        try check(hashResult?.memoType == "returnHash" && hashResult?.memo == String(repeating: "07", count: 32), "SEP7 hash memo changed")
        try check(recipient("ton:transfer/\(ton)?amount=10&text=hello")?.memo == "hello", "TON comment lost")
        let sol = try SolanaSendCrypto.address(privateKey: ed)
        try check(recipient("solana:\(sol)?amount=1&memo=hello")?.memo == "hello", "Solana memo lost")
        try check(invalid("bitcoin:\(btc)?text=unsupported"), "Unsupported comment discarded")
        for (id, chain) in networkIDs {
            let result = recipient("ethereum:\(addresses[0].1)@\(id)?value=1000000000000000")
            try check(result?.networks == [chain] && result?.amountIsAtomic == true, "EIP681 chain identity lost")
            let contract = "0x" + String(repeating: "ab", count: 20)
            let tokenPayment = recipient("ethereum:\(contract)@\(id)/transfer?address=\(addresses[0].1)&uint256=42")!
            try check(tokenPayment.matchesAsset(networkID: chain.id, reference: "0x" + String(repeating: "AB", count: 20)), "Requested EVM token excluded by case")
            try check(!tokenPayment.matchesAsset(networkID: chain.id, reference: "native"), "Token payment listed native coin")
            try check(!tokenPayment.matchesAsset(networkID: chain.id, reference: addresses[0].1), "Token payment listed a different contract")
            try check(tokenPayment.amount == "42" && tokenPayment.amountIsAtomic && tokenPayment.token == contract, "Token payment intent lost before asset selection")
            for other in networkIDs.values where other != chain {
                try check(!tokenPayment.matchesAsset(networkID: other.id, reference: contract), "Token payment crossed networks")
            }
        }
        let solanaToken = try SolanaSendCrypto.address(privateKey: Data(repeating: 42, count: 32))
        let solanaPayment = recipient("solana:\(sol)?spl-token=\(solanaToken)&amount=1&memo=hello")!
        try check(solanaPayment.matchesAsset(networkID: "solana", reference: solanaToken), "Solana token payment excluded")
        try check(!solanaPayment.matchesAsset(networkID: "solana", reference: solanaToken.lowercased()), "Case-sensitive token reference matched incorrectly")
        try check(solanaPayment.decoded(on: .solana)?.memo == "hello", "Token payment memo lost")
        // Payment QR matrix uses the actual chain registry and real image decoder.
        var paymentChains = Set<OathImportChain>(), tokenChains = Set<OathImportChain>()
        for chain in OathImportChain.allCases {
            let destination = addresses.first { $0.0 == chain }!.1
            let uri: String
            if chain.isEVM {
                let id = networkIDs.first { $0.value == chain }!.key
                uri = "ethereum:\(destination)@\(id)?value=2.5e6"
            } else if chain == .ton {
                uri = "ton://transfer/\(destination)?amount=2500000"
            } else {
                let target = chain == .bitcoincash ? destination.replacingOccurrences(of: "bitcoincash:", with: "") : destination
                uri = "\(chain.id):\(target)?amount=2.5"
            }
            guard let result = recipient(try qr(uri)) else { throw Failure.assertion("Native payment QR rejected: " + chain.id) }
            try check(result.networks == [chain], "Native payment network lost: " + chain.id)
            try check(result.amount == (chain.isEVM || chain == .ton ? "2500000" : "2.5"), "Payment amount scale lost")
            try check(result.decoded(on: chain) != nil && OathScannerContext.home.route(result) == .assets, "Native QR must retain asset selection")
            paymentChains.insert(chain)
            if chain.supportsTokens {
                guard let tokenResult = recipient(try qr("usdt:\(destination)?amount=200.125")) else { throw Failure.assertion("Ticker payment rejected: " + chain.id) }
                try check(tokenResult.networks.contains(chain) && tokenResult.amount == "200.125", "Token payment units/network lost")
                try check(tokenResult.token == nil && tokenResult.tokenSymbol == "USDT", "Ticker QR must not invent a token contract")
                try check(tokenResult.matchesAsset(networkID: chain.id, reference: "fixture", symbol: "USDT"), "Matching ticker not recognized")
                try check(!tokenResult.matchesAsset(networkID: chain.id, reference: "native", symbol: "OTHER"), "Token amount can leak to native coin")
                tokenChains.insert(chain)
            }
        }
        try check(paymentChains == Set(OathImportChain.allCases), "Native payment matrix incomplete")
        try check(tokenChains == Set(OathImportChain.allCases.filter(\.supportsTokens)), "Token payment matrix incomplete")
        // Exact reported payload, with a public synthetic recipient substituted.
        let exchange = recipient(try qr("usdt:\(addresses[0].1)?amount=200"))!
        try check(exchange.networks.contains(.bnb) && exchange.networks.contains(.ethereum), "Ticker-only QR must not assume BNB")
        try check(exchange.matchesAsset(networkID: "bnb", reference: "0x55d398326f99059ff775485246999027b3197955", symbol: "BSC-USD"), "BNB catalog alias must match exact USDT contract")
        try check(!exchange.matchesAsset(networkID: "bnb", reference: "0x4444444444444444444444444444444444444444", symbol: "BSC-USD"), "USDT alias must not match arbitrary contracts")
        if let fixture = ProcessInfo.processInfo.environment["OATH_PAYMENT_QR_FIXTURE"] {
            let codes = try OathScanImage.codes(in: Data(contentsOf: URL(fileURLWithPath: fixture)))
            try check(codes.count == 1, "Invoice screenshot must decode one QR")
            let invoice = recipient(codes[0])
            try check(invoice?.tokenSymbol == "USDT" && invoice?.amount == "200" && invoice?.networks.contains(.bnb) == true, "Reported invoice must parse through production decoder and parser")
        }
        let legacyInvoice = "ethereum:0x3E6D14A9e27eD8eAbC2B8669Df45968Dd8D4ebeB?amount=50"
        let legacyRequest = recipient(try qr(legacyInvoice))
        try check(legacyRequest?.amount == "50" && legacyRequest?.amountIsAtomic == false && legacyRequest?.amountAssetUnspecified == true, "Exchange amount must remain selected-asset units")
        try check(Set(legacyRequest?.networks ?? []) == Set(OathImportChain.allCases.filter(\.isEVM)), "Exchange QR must not invent BSC from an unqualified address")
        try check(legacyRequest?.matchesAsset(networkID: "bnb", reference: "0x55d398326f99059ff775485246999027b3197955") == true, "Exchange quantity must apply to selected BSC USDT")
        if let fixture = ProcessInfo.processInfo.environment["OATH_LEGACY_PAYMENT_QR_FIXTURE"] {
            let codes = try OathScanImage.codes(in: Data(contentsOf: URL(fileURLWithPath: fixture)))
            try check(codes == [legacyInvoice], "Reported screenshot QR differs from regression payload")
            try check(recipient(codes[0]) == legacyRequest, "Actual screenshot failed production parsing")
        }
        for (id, chain) in networkIDs {
            let result = recipient(try qr("ethereum:\(addresses[0].1)@\(id)?amount=50&label=Merchant&message=Order%20%23123"))
            try check(result?.networks == [chain] && result?.amount == "50" && result?.displayNote == "Merchant\nOrder #123", "EVM human units and notes lost: " + chain.id)
            try check(invalid("ethereum:\(addresses[0].1)@\(id)?amount=50&value=1"), "Conflicting amount scales accepted")
            try check(recipient("\(chain.id):\(addresses[0].1)?value=1e3")?.amount == "1000", "EVM alias did not preserve atomic units")
        }
        for chain in OathImportChain.allCases {
            let target = addresses.first { $0.0 == chain }!.1.replacingOccurrences(of: "bitcoincash:", with: "")
            let base = chain == .ton ? "ton://transfer/" : chain.id + ":"
            let note = recipient(try qr(base + target + "?amount=1&label=Shop&message=Thanks%20for%20the%20order"))
            try check(note?.displayNote == "Shop\nThanks for the order", "QR note lost: " + chain.id)
            try check(recipient(base + target + "?message=Thanks for the order")?.message == "Thanks for the order", "URI with spaces misclassified as recovery: " + chain.id)
            print("PASS payment QR image, amount and notes: " + chain.id)
        }
        try check(recipient("thorchain:" + thor + "?memo=OUT%3Atest")?.memo == "OUT:test", "THORChain memo rejected")
        try check(invalid("xrpl:" + classic + "?memo=1&dt=2"), "Conflicting destination tags accepted")
        try check(recipient(payment + "&optional-future=value")?.amount == "0.001", "BIP21 optional extension rejected")
        try check(recipient(payment + "&optional-flag")?.amount == "0.001", "BIP21 valueless optional extension rejected")
        try check(recipient("bitcoin:" + btc + "?amount=.5")?.amount == "0.5", "BIP21 leading decimal rejected")
        try check(recipient("bitcoin:" + btc + "?amount=1.")?.amount == "1.0", "BIP21 trailing decimal rejected")
        try check(invalid("bitcoin:" + btc + "?amount=."), "Empty decimal accepted")
        try check(invalid("bsc:" + addresses[0].1 + "@1?value=1"), "Conflicting chain selector accepted")
        try check(recipient("ethereum:" + addresses[0].1 + "?value=1000e-3&gas=21000")?.amount == "1", "Exact scientific integer or gas suggestion rejected")
        let referenceURI = "solana:" + sol + "?amount=0.5&reference=" + solanaToken + "&reference=" + solanaToken + "&memo=Order%20123"
        let references = recipient(try qr(referenceURI))
        try check(references?.solanaReferences == [solanaToken, solanaToken] && references?.memo == "Order 123", "Solana Pay reference order or duplicates lost")
        try check(invalid("solana:" + sol + "?reference=bad"), "Invalid Solana Pay reference accepted")
        try check(invalid("bitcoin:" + btc + "?req-reference=" + solanaToken), "Required unknown instruction ignored")
        struct Choice { let network: String; let reference: String; let symbol: String }
        let choices = [Choice(network: "bnb", reference: "native", symbol: "BNB"),
                       Choice(network: "bnb", reference: "one", symbol: "USDT"),
                       Choice(network: "bnb", reference: "two", symbol: "USDT"),
                       Choice(network: "bitcoin", reference: "native", symbol: "BTC")]
        let ranked = exchange.prioritized(choices, network: { $0.network }, reference: { $0.reference }, symbol: { $0.symbol })
        try check(ranked.map(\.reference) == ["one", "two", "native"], "Payment matching must promote, retain alternatives, and preserve tie order")
        for (input, expected) in [("+2e6", "2000000"), ("2.014e18", "2014000000000000000"), ("2e+6", "2000000"), ("00042", "42"), ("0", "0")] {
            try check(OathScanParser.normalizedAmount(input, atomic: true, scientific: true) == expected, "EIP681 integer expansion changed precision")
        }
        for input in ["-1", "NaN", "Infinity", "1e999999", "1e-6", "1.25e1", "1e", "1..2", ".1", "1.", "1,000"] {
            try check(OathScanParser.normalizedAmount(input, atomic: true, scientific: true) == nil, "Malformed/overflow atomic amount accepted")
        }
        try check(invalid("usdt:\(addresses[0].1)?amount=1&amount=200"), "Duplicate ticker amount accepted")
        try check(invalid("usdt:\(addresses[0].1)?amount=1&chain=56"), "Unknown network instruction discarded")
        try check(invalid("https:\(addresses[0].1)?amount=1"), "Web scheme mistaken for ticker")
        try check(invalid("ethereum:\(addresses[0].1)?address=\(addresses[0].1)&uint256=1"), "Unexecuted ABI fields discarded")
        let noQuantity = recipient("ethereum:\(addresses[0].1)@56/transfer?address=\(addresses[0].1)")!
        try check(noQuantity.token != nil && noQuantity.amount == nil, "Token request without quantity must permit amount entry")
        try check(OathScannerContext.contact(.bnb).route(exchange) == .review, "Ticker payment must not become a plain contact")
        try check(invalid("ton://transfer/\(ton)?amount=1&memo=ignored"), "Unsupported TON memo must not be silently dropped")
        let noNetwork = recipient("ethereum:\(addresses[0].1)?value=1")!
        try check(Set(noNetwork.networks) == Set(OathImportChain.allCases.filter(\.isEVM)), "Unspecified EVM network must remain selectable")
        let issued = recipient(try qr("web+stellar:pay?destination=\(stellar)&amount=2.5&asset_code=USDT&asset_issuer=\(stellar)"))!
        try check(issued.token == (try StellarIdentity.contract(code: "USDT", issuer: stellar)) && issued.amount == "2.5", "SEP7 issuer identity lost")
        for (type, value, expectedType) in [("MEMO_TEXT", "Invoice", "text"), ("MEMO_ID", "18446744073709551615", "id"),
            ("MEMO_HASH", Data(repeating: 0, count: 32).base64EncodedString(), "hash"),
            ("MEMO_RETURN", Data(repeating: 0, count: 32).base64EncodedString(), "returnHash")] {
            let payment = recipient(try qr("web+stellar:pay?destination=\(stellar)&amount=2.5&memo_type=\(type)&memo=\(value)"))
            try check(payment?.memoType == expectedType && payment?.hasExactAsset == true, "SEP7 standard memo type rejected")
            try check(payment?.memo == (type == "MEMO_HASH" || type == "MEMO_RETURN" ? String(repeating: "00", count: 32) : value), "SEP7 memo contents changed")
        }
        try check(invalid("web+stellar:pay?destination=\(stellar)&amount=2&network_passphrase=Testnet"), "Stellar testnet request silently became mainnet")
        try check(invalid(stellar + "?amount=1&memo=" + String(repeating: "a", count: 29)), "Schemeless Stellar text memo overflow accepted")
        try check(recipient(classic + "?amount=1&dt=123")?.memo == "123", "Schemeless XRP destination tag lost")
        try check(invalid(classic + "?amount=1&dt=4294967296"), "Schemeless XRP destination tag overflow accepted")
        let jetton = recipient(try qr("ton://transfer/\(ton)?jetton=\(ton)&amount=2500000&text=invoice"))!
        try check(jetton.amountIsAtomic && jetton.amount == "2500000" && jetton.memo == "invoice", "Jetton amount/comment lost")
        try check(jetton.matchesAsset(networkID: "ton", reference: try TonIdentity.raw(ton)), "Jetton friendly/raw identity mismatch")
        let wc = "wc:" + String(repeating: "a", count: 64) + "@2?relay-protocol=irn&symKey=" + String(repeating: "b", count: 64)
        if case .walletConnect = parser.parse(try qr(wc)) { checks += 1 } else { throw Failure.assertion("WCv2 rejected") }
        for context in [OathScannerContext.home, .walletConnect, .recipient(.ethereum), .contact(.ethereum), .recovery, .privateKey] {
            try check(context.destination(for: parser.parse(wc)) == .connection,
                      "A valid WalletConnect scan must open connection consent without a preliminary review")
            for malformed in [wc + "&expiryTimestamp=1", wc.replacingOccurrences(of: "@2", with: "@1"), wc + "&symKey=invalid"] {
                try check(context.destination(for: parser.parse(malformed)) == .review,
                          "Invalid or expired pairing must not open connection consent")
            }
            try check(context.destination(for: .privateKey("fixture")) == .review,
                      "Private-key import still requires explicit review")
        }
        let assetContext = OathScannerContext.asset(.ethereum, reference: "native", symbol: "ETH")
        try check(assetContext.destination(for: parser.parse(wc)) == .review,
                  "Payment-only asset scanner must not open a connection")
        try check(OathScannerContext.home.destination(for: .recipient(bitcoinPayment)) == .recipient(.assets),
                  "Removing connection pre-review must preserve Home payment selection")
        try check(invalid(wc + "&expiryTimestamp=1"), "Expired pairing accepted")
        try check(invalid(wc.replacingOccurrences(of: "@2", with: "@1")), "WCv1 accepted")
        try check(OathWalletConnectPolicy.personalMessage(["0x6869", addresses[0].1], account: addresses[0].1) == Data("hi".utf8), "Personal message bytes changed")
        try check(OathWalletConnectPolicy.personalMessage(["0x6869", "0x1"], account: addresses[0].1) == nil, "Wrong signing account accepted")
        try check(OathWalletConnectPolicy.personalMessage(["0x" + String(repeating: "ab", count: 4097), addresses[0].1], account: addresses[0].1) == nil, "Oversized signature request accepted")
        try check(!OathWalletConnectPolicy.methods.contains("eth_sign"), "Blind signing enabled")
        try check(OathWalletConnectPolicy.methods(namespace: "cosmos") == ["cosmos_getAccounts", "cosmos_signAmino", "cosmos_signDirect"], "THORChain permissions missing")
        try check(OathWalletConnectPolicy.methods(namespace: "eip155").isDisjoint(with: OathWalletConnectPolicy.methods(namespace: "cosmos")), "Cross-namespace methods leaked")
        try check(OathWalletConnectPolicy.methods(namespace: "unknown").isEmpty, "Unknown namespace enabled")
        try check(OathWalletConnectPolicy.safeHost("https://trusted.example@evil.example") == nil, "Deceptive origin accepted")
        let signatures = try JSONDecoder().decode([MessageVector].self, from: Data(contentsOf: root.appendingPathComponent("Tools/Fixtures/WalletConnectMessageVectors.json")))
        for vector in signatures {
            let bytes = Data(vector.message.utf8)
            try check("0x" + OathWalletConnectMessage.digest(bytes).map { String(format: "%02x", $0) }.joined() == vector.digest, "EIP191 UTF8 digest differs from ethers")
            try check(try OathWalletConnectMessage.sign(bytes, key: scalar, account: vector.address) == vector.signature, "Signature differs from ethers")
        }
        print("Passed \(checks) scanner checks; \(qrCount) real CoreImage/Vision QR round trips; \(covered.count) chains; \(vectorCount) public BIP39 vectors across \(languages.count) languages. No wallet data, simulator, camera, or network used.")
    }
}
