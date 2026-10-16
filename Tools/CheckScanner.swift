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
            (.near, "scanner.near"), (.near, String(repeating: "ab", count: 32)),
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
            covered.insert(chain)
        }
        try check(covered == Set(OathImportChain.allCases), "Chain catalog coverage incomplete")
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
        let wc = "wc:" + String(repeating: "a", count: 64) + "@2?relay-protocol=irn&symKey=" + String(repeating: "b", count: 64)
        if case .walletConnect = parser.parse(try qr(wc)) { checks += 1 } else { throw Failure.assertion("WCv2 rejected") }
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
