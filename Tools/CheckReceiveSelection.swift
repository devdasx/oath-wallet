import Foundation
import OathDatabase
import Vision

/// Public/synthetic fixtures only. Exercise production account mapping and QR
/// encoding on the Mac without launching the app, simulator or camera.
@main struct CheckReceiveSelection {
    static func displayed(_ qr: CGImage, pixels: Int, checkerLogo: Bool) -> CGImage {
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bounds = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        context.interpolationQuality = .none
        context.draw(qr, in: bounds)
        // Conservative square backing covers at least as much QR data as the
        // rounded-square Receive overlay, including existing circular caches.
        // A solid square logo is likewise stricter than the rounded artwork.
        let badge = OathReceiveQRCode.centeredRect(in: bounds, fraction: OathReceiveQRCode.badgeFraction)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(badge)
        let logo = OathReceiveQRCode.centeredRect(in: bounds, fraction: OathReceiveQRCode.logoFraction)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(logo)
        if checkerLogo {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            let cell = logo.width / 5
            for row in 0..<5 {
                for column in 0..<5 where (row + column) % 2 == 0 {
                    context.fill(CGRect(x: logo.minX + CGFloat(column) * cell,
                        y: logo.minY + CGFloat(row) * cell, width: cell, height: cell))
                }
            }
        }
        return context.makeImage()!
    }

    static func holding(account: String, network: String, address: String, reference: String,
                        name: String = "USDC", symbol: String = "USDC", amount: String? = "1234500") throws -> Holding {
        var object: [String: Any] = ["accountID": account, "networkID": network, "address": address,
            "assetID": network + ":" + reference, "reference": reference, "name": name,
            "symbol": symbol, "decimals": 6, "transactionCount": 0,
            "usdPrice": "1", "exchangeRate": "0.92"]
        object["amountAtomic"] = amount
        return try JSONDecoder().decode(Holding.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func main() async throws {
        try checkSearchRanking()
        if CommandLine.arguments.contains("--search-ranking-only") { return }
        try await checkFeeFunding()
        if CommandLine.arguments.contains("--fee-funding-only") { return }
        // First render is measured before any other Core Image work. These are
        // host measurements, not claims about a phone's launch/frame timing.
        for index in 0..<8 {
            let start = ContinuousClock.now
            let image = await Task.detached(priority: .userInitiated) {
                OathReceiveQRCode.image(for: "0x" + String(repeating: "a3", count: 20))
            }.value
            precondition(image != nil)
            print("Host QR render \(index): \(start.duration(to: .now))")
        }
        try await CheckReceivePreparation.run()
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1; precondition(value(), message)
        }
        let first = OathWalletAddress(chain: .ethereum, address: "first-account", path: "first-path", accountID: "one")
        let second = OathWalletAddress(chain: .ethereum, address: "second-account", path: "second-path", accountIndex: 1, accountID: "two")
        let solana = OathWalletAddress(chain: .solana, address: "old-path-address", path: "solana-path", accountID: "sol")
        let token = try holding(account: "two", network: "ethereum", address: second.address, reference: "token")
        let native = try holding(account: "one", network: "ethereum", address: first.address, reference: "native", name: "Ethereum", symbol: "ETH")
        let unknown = try holding(account: "one", network: "ethereum", address: first.address, reference: "unknown", amount: nil)
        let solToken = try holding(account: "sol", network: "solana", address: "current-path-address", reference: "mint")
        let unrelated = try holding(account: "other-wallet", network: "ethereum", address: "wrong-wallet", reference: "native")
        let wrongChain = try holding(account: "one", network: "arbitrum", address: first.address, reference: "native")
        let holdings = [token, native, unknown, solToken, unrelated, wrongChain]
        let accounts = [first, second, solana]
        check(OathReceiveAsset.directAddress(in: []) == nil, "Empty wallets retain the picker")
        check(OathReceiveAsset.directAddress(in: [first, second]) == nil, "Two accounts on one chain are still distinct choices")
        check(OathReceiveAsset.directAddress(in: [first, solana]) == nil, "Multiple networks retain the picker")
        for chain in OathImportChain.allCases {
            let only = OathWalletAddress(chain: chain, address: "public-fixture", path: "imported", accountID: chain.id)
            let nativeOnly = [OathImportChain.bitcoin, .bitcoincash, .dogecoin, .litecoin].contains(chain)
            check(OathReceiveAsset.directAddress(in: [only]) == (nativeOnly ? only : nil),
                  "Receive keeps token selection even with one account: " + chain.id)
        }
        let rows = OathReceiveAsset.available(holdings: holdings, addresses: accounts, query: "")
        check(rows.map(\.holding) == [token, native, unknown, solToken], "Preserve selection order and exact balances; exclude unrelated accounts and networks")
        check(rows[0].address.accountID == "two" && rows[0].address.address == second.address, "A second account never resolves to the first account on its network")
        check(rows[0].address.assetID == token.assetID && rows[0].address.accountIndex == 1, "Token receive retains the exact asset/account identity")
        check(rows[0].address.path == second.path, "Keep correct account derivation")
        check(rows[0].holding.nativeDisplayValue == Decimal(string: "1.2345"), "Keep native quantity")
        check(rows[0].holding.fiatDisplayValue == Decimal(string: "1.13574"), "Keep selected-currency valuation")
        check(rows[2].holding.amountAtomic == nil, "Unknown balances never become zero")
        check(rows[3].address.address == "current-path-address", "Use the active holding owner after a receive-path change")
        check(OathReceiveAsset.available(holdings: holdings, addresses: accounts, query: "ethereum usdc").map(\.id) == [token.id, unknown.id], "Search every word across identity fields")
        check(OathReceiveAsset.available(holdings: holdings, addresses: accounts, query: "nonexistent").isEmpty, "Search miss is an empty state")
        check(OathReceiveAsset.available(holdings: holdings, addresses: [], query: "").isEmpty, "No fallback to another wallet")
        check(OathReceiveAsset.available(holdings: holdings, addresses: accounts + [first], query: "").count == rows.count, "Repeated account metadata never duplicates assets or crashes")

        for chain in OathImportChain.allCases {
            // Distinct address vs contract ensures QR never encodes a token's contract.
            let owner = "public-receive-fixture-" + chain.id
            let account = OathWalletAddress(chain: chain, address: owner, path: "fixture-path", accountID: chain.id)
            let h = try holding(account: chain.id, network: chain.id, address: owner, reference: "contract-fixture")
            let result = OathReceiveAsset.available(holdings: [h], addresses: [account], query: "")
            check(result.count == 1 && result[0].address.chain == chain, "Every supported network maps its own account")
            let image = OathReceiveQRCode.image(for: result[0].address.address)!
            let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: image).perform([request])
            check(request.results?.first?.payloadStringValue == owner, "QR round-trip is the receive address, never the contract")
        }
        // Payload lengths/alphabets used by the supported chains, including
        // Taproot, 32-byte hex, implicit/named NEAR and both TON encodings.
        // These exercise QR encoding, not address validity or network access.
        let addressShapes = [
            "bc1q7cx62nq69tzwtl7fp080trqxrxwzf5pnzjrd7n",
            "bc1p" + String(repeating: "q", count: 58),
            "bitcoincash:q" + String(repeating: "p", count: 41),
            "ltc1q" + String(repeating: "q", count: 38),
            "D" + String(repeating: "a", count: 33),
            "0x" + String(repeating: "a3", count: 20),
            "0x" + String(repeating: "c4", count: 32),
            String(repeating: "e5", count: 32),
            "public-receive-fixture.near",
            "G" + String(repeating: "B", count: 55),
            "EQ" + String(repeating: "aB3_", count: 11) + "AB",
            "0:" + String(repeating: "af", count: 32),
            "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
            "So11111111111111111111111111111111111111112",
            "r" + String(repeating: "P", count: 33)
        ]
        check(OathReceiveQRCode.image(for: "") == nil, "Empty addresses never produce a code")
        var brandedDecodes = 0
        for payload in addressShapes {
            let qr = OathReceiveQRCode.image(for: payload)!
            check(qr.width == qr.height && qr.width % 8 == 0, "Integer module scaling and square image")
            // The narrow 320-point sheet, the usual size and the large-sheet
            // cap all retain the same native Core Image matrix and protected logo area.
            for side in [275, Int(OathReceiveQRCode.displaySide), 360, 378] {
                for scale in [1, 2, 3] {
                    for checker in [false, true] {
                        let image = displayed(qr, pixels: side * scale, checkerLogo: checker)
                        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
                        try VNImageRequestHandler(cgImage: image).perform([request])
                        check(request.results?.contains { $0.payloadStringValue == payload } == true,
                              "Branded QR must decode the exact address at \(side)pt / \(scale)x with a \(checker ? "detailed" : "solid") center logo")
                        brandedDecodes += 1
                    }
                }
            }
        }
        print("Passed \(checks) receive-selection checks, \(OathImportChain.allCases.count) network QR round-trips and \(brandedDecodes) branded QR decodes at 1x/2x/3x. Host only.")
    }

    static func checkSearchRanking() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1; precondition(value(), message)
        }
        for chain in OathImportChain.allCases {
            let account = OathWalletAddress(chain: chain, address: "public-first", path: "first-path", accountID: "first")
            let second = OathWalletAddress(chain: chain, address: "public-second", path: "second-path",
                                          accountIndex: 1, accountID: "second")
            let funded = try holding(account: "first", network: chain.id, address: account.address,
                                    reference: "token-one", name: "Search Fixture", symbol: "FIND", amount: "999999999")
            let unknown = try holding(account: "first", network: chain.id, address: account.address,
                                     reference: "native", name: "Native Coin", symbol: chain.ticker, amount: nil)
            let zero = try holding(account: "second", network: chain.id, address: second.address,
                                  reference: "native", name: "Native Coin", symbol: chain.ticker, amount: "0")
            let sameSymbol = try holding(account: "first", network: chain.id, address: account.address,
                                        reference: "token-two", name: "Native Coin", symbol: chain.ticker, amount: "1000000")
            let input = [funded, sameSymbol, zero, unknown]
            let accounts = [account, second]
            for query in [chain.id, chain.name, "  \(chain.name.uppercased())  "] {
                let rows = OathReceiveAsset.available(holdings: input, addresses: accounts, query: query)
                check(rows.map(\.holding) == [zero, unknown, funded, sameSymbol],
                      "Native receive assets lead network searches, retaining stable order and exact balances: \(chain.id), \(query)")
                check(rows.first?.address.accountID == second.accountID && rows.first?.address.address == second.address,
                      "Ranking preserves the selected native account: \(chain.id)")
            }
            check(OathReceiveAsset.available(holdings: input, addresses: accounts, query: chain.ticker).first?.holding == zero,
                  "A token sharing the native ticker cannot outrank the native asset: \(chain.id)")
            check(OathReceiveAsset.available(holdings: input, addresses: accounts, query: chain.name + " FIND").map(\.holding) == [funded],
                  "Token-specific searches do not insert unrelated native coins: \(chain.id)")
            check(OathReceiveAsset.available(holdings: input, addresses: accounts, query: "token-two").map(\.holding) == [sameSymbol],
                  "Exact token-reference searches remain token-specific: \(chain.id)")
            check(OathReceiveAsset.available(holdings: input, addresses: [], query: chain.id).isEmpty,
                  "Search ranking cannot include another wallet's accounts: \(chain.id)")
            for query in ["", " \n\t "] {
                check(OathReceiveAsset.available(holdings: input, addresses: accounts, query: query).map(\.holding) == input,
                      "Clearing search restores the portfolio order: \(chain.id)")
            }
        }
        print("Passed \(checks) Receive search-ranking checks across \(OathImportChain.allCases.count) networks. Host only.")
    }

    static func checkFeeFunding() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oath-fee-receive-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("fixture.sqlite"))
        let chains = OathImportChain.allCases.filter(\.supportsTokens)
        var checks = 0
        for chain in chains {
            let wallet = "fee-" + chain.id
            let first = AccountRecord(id: wallet + "-first", walletID: wallet, networkID: chain.id,
                                      address: "first-public-account", derivationPath: "first-path")
            let sender = AccountRecord(id: wallet + "-sender", walletID: wallet, networkID: chain.id,
                                       address: "sender-public-account", derivationPath: "sender-path", accountIndex: 1)
            try await db.seed(networks: [.init(id: chain.id, name: chain.name, family: "account", symbol: chain.ticker,
                decimals: 18, derivationPath: "fixture", logo: chain.logoAsset, sortOrder: 0)], assets: [])
            try await db.importWalletIfNeeded(.init(id: wallet, name: "Fixture", kind: "hd", vaultReference: wallet, createdAt: 1),
                                             accounts: [first, sender])
            let snapshot = try await db.snapshot(walletID: wallet, currency: "USD")
            let token = try holding(account: sender.id, network: chain.id, address: sender.address, reference: "token-contract")
            let receive = OathReceiveAsset.feeAddress(for: token, in: snapshot)
            precondition(receive?.address == sender.address && receive?.chain == chain)
            precondition(receive?.accountID == sender.id && receive?.accountIndex == 1 && receive?.path == sender.derivationPath)
            precondition(receive?.assetID == chain.id + ":native", "An absent/hidden native holding still receives the fee coin")
            let foreign = try holding(account: "unrelated-wallet", network: chain.id, address: "foreign", reference: "native")
            precondition(OathReceiveAsset.feeAddress(for: foreign, in: snapshot) == nil)
            let mismatch = try holding(account: sender.id, network: chain == .base ? "ethereum" : "base", address: sender.address, reference: "native")
            precondition(OathReceiveAsset.feeAddress(for: mismatch, in: snapshot) == nil)
            try await db.seed(networks: [], assets: [.init(id: chain.id + ":native", networkID: chain.id, reference: "native",
                name: chain.name, symbol: chain.ticker, decimals: 18)])
            let fundedSnapshot = try await db.snapshot(walletID: wallet, currency: "USD")
            precondition(OathReceiveAsset.feeAddress(for: token, in: fundedSnapshot) == receive)
            checks += 6
        }
        print("Passed \(checks) native-fee receive checks across \(chains.count) token networks: sender/account isolation, network isolation, native asset selection and missing native holdings. Host only.")
    }
}
