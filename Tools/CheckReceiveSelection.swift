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

    static func main() throws {
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
            for side in [275, Int(OathReceiveQRCode.displaySide), 360] {
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
}
