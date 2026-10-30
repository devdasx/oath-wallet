import Foundation
import CryptoKit
import ImageIO
import Vision
import OathAnkr

/// Mac-host checks. No wallet, simulator, device, credential or balance RPC.
@main struct CheckReceiveExperience {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(condition(), message)
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let catalog = try JSONDecoder().decode(OathReceiveExampleCatalog.self,
            from: Data(contentsOf: root.appendingPathComponent("OathApp/Resources/ReceiveAssets.json")))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("Design/ReceiveAssets/manifest.json"))) as! [String: Any]
        let sources = manifest["assets"] as! [[String: Any]]
        let nativeOnly: Set<OathImportChain> = [.bitcoin, .bitcoincash, .dogecoin, .litecoin]
        let tokenChains = Set(OathImportChain.allCases.filter(\.supportsTokens))
        check(Set(catalog.networks.keys) == Set(tokenChains.map(\.id)), "Every token-capable network has examples")
        let allExamples = catalog.networks.values.flatMap { $0 }
        check(Set(sources.compactMap { $0["id"] as? String }) == Set(allExamples.map(\.id)), "Manifest covers exactly the shipped examples")
        check(sources.count == allExamples.count, "One provenance record per example")
        let seed = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(
            "Packages/OathAnkr/Sources/OathAnkr/Resources/TokenDiscoverySeed.json"))) as! [String: Any]
        let seedEntries = seed["entries"] as! [[String: Any]]

        for chain in OathImportChain.allCases {
            let guide = OathReceiveNetworkGuide(chain: chain)
            let examples = catalog.examples(for: chain)
            check(guide.supportsTokens == !nativeOnly.contains(chain), "Receiving capability for \(chain.id)")
            check(tokenChains.contains(chain) ? (1...10).contains(examples.count) : examples.isEmpty,
                  "Verified examples on token networks only: \(chain.id)")
            check(examples.count == (catalog.networks[chain.id]?.count ?? 0), "No examples hidden by the display limit")
            check(Set(examples.map(\.id)).count == examples.count, "Unique contract identities within \(chain.id)")
            for example in examples {
                check(example.id.hasPrefix(chain.id + ":"), "Never reuse another network's token entry")
                check(!example.name.isEmpty && !example.symbol.isEmpty, "Accessible token identity")
                let source = sources.first { $0["id"] as? String == example.id }!
                check(source["network"] as? String == chain.id, "Catalog matches source network")
                check(source["artwork"] as? String == example.artwork, "Catalog matches source logo")
                check(example.id == chain.id + ":" + (source["reference"] as! String), "Exact token reference")
                let reference = source["reference"] as! String
                let expectedArtwork = example.usesRedesignedArtwork == true ? example.artwork : nil
                check(catalog.redesignedArtwork(networkID: chain.id, reference: reference) == expectedArtwork,
                      "Receive and all token surfaces select the same exact-identity design")
                if chain.isEVM {
                    check(catalog.redesignedArtwork(networkID: chain.id, reference: reference.uppercased()) == expectedArtwork,
                          "Checksummed EVM contracts resolve to the same bundled artwork")
                }
                if reference != "native" {
                    let canonical = try TokenDiscoveryNetworks.canonical(reference, network: chain.id)
                    // Native ERC-20 interfaces retain their explicit contract key
                    // in the example catalog instead of replacing the chain icon.
                    if canonical != "native" {
                        check(catalog.redesignedArtwork(networkID: chain.id, reference: canonical) == expectedArtwork,
                              "Stored holding identity uses the same design as Receive: \(example.id)")
                    }
                    if chain == .ton {
                        let alternate = try TonIdentity.friendly(reference, bounceable: false)
                        check(catalog.redesignedArtwork(networkID: chain.id, reference: alternate) == expectedArtwork,
                              "TON non-bounceable identity shares the exact jetton artwork")
                    }
                    if chain == .stellar, reference.contains("-") {
                        check(catalog.redesignedArtwork(networkID: chain.id, reference: reference.replacingOccurrences(of: "-", with: ":")) == expectedArtwork,
                              "Stellar issuer notation shares the exact asset artwork")
                    }
                    if chain == .sui, reference.contains("::") {
                        let parts = reference.components(separatedBy: "::")
                        let padded = try AptosIdentity.address(parts[0]) + "::" + parts.dropFirst().joined(separator: "::")
                        check(catalog.redesignedArtwork(networkID: chain.id, reference: padded) == expectedArtwork,
                              "Padded Move package identities retain their artwork")
                    }
                }
                if let coinID = source["coinID"] as? String {
                    check(seedEntries.contains { $0["network"] as? String == chain.id
                        && $0["reference"] as? String == source["reference"] as? String
                        && $0["coinID"] as? String == coinID }, "New example matches the shared discovery identity")
                }
                let category = example.artwork.hasPrefix("network-") ? "Networks" : "ReceiveAssets"
                let folder = root.appendingPathComponent("OathApp/Assets.xcassets/\(category)/\(example.artwork).imageset")
                let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("Contents.json"))) as! [String: Any]
                let properties = contents["properties"] as! [String: Any]
                check(properties["template-rendering-intent"] as? String == "original", "Original brand colors")
                let filename = (contents["images"] as! [[String: Any]])[0]["filename"] as! String
                let data = try Data(contentsOf: folder.appendingPathComponent(filename))
                if let expected = source["sha256"] as? String {
                    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    check(hash == expected, "Logo matches recorded provenance")
                }
                if filename.hasSuffix(".pdf") {
                    let pdf = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init)
                    check(pdf?.numberOfPages == 1, "Existing network vector artwork")
                    check(properties["preserves-vector-representation"] as? Bool == true, "Vector artwork remains scalable")
                } else if filename.hasSuffix(".svg") {
                    check(String(data: data, encoding: .utf8)?.contains("<svg") == true, "Existing network vector artwork")
                    check(properties["preserves-vector-representation"] as? Bool == true, "Vector artwork remains scalable")
                } else {
                    let image = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                    check(image != nil, "Every bundled logo decodes offline: \(example.id)")
                    check(image!.width >= 102 && image!.height >= 102, "Logo covers the 34-point detail badge at 3x: \(example.id)")
                }
            }
        }
        let redesigned = allExamples.filter { $0.usesRedesignedArtwork == true }
        check(redesigned.count == 268, "Every exported example uses the delivered design")
        check(Set(redesigned.map(\.artwork)).count == 196, "All 196 delivered artwork entries are shared without identity guesses")
        for chain in OathImportChain.allCases {
            check(catalog.redesignedArtwork(networkID: chain.id, reference: "native") == (chain == .telos ? "receive-asset-telos-native" : nil),
                  "Only the explicitly supplied native Telos example overrides a chain logo")
            check(catalog.redesignedArtwork(networkID: chain.id, reference: "USDC") == nil, "A ticker never grants branded token artwork")
            check(catalog.redesignedArtwork(networkID: chain.id, reference: "0x0000000000000000000000000000000000000001") == nil,
                  "Unlisted contracts keep their normal artwork resolver")
        }
        check(catalog.redesignedArtwork(networkID: "unknown", reference: "assets:1337") == nil, "Unknown networks cannot inherit another chain's logo")
        check(catalog.redesignedArtwork(networkID: "polkadot", reference: "assets:1337") != nil, "Asset Hub identities retain their namespaced reference")
        check(catalog.redesignedArtwork(networkID: "thorchain", reference: "x/ruji") != nil, "THORChain bank-denomination artwork")
        check(catalog.redesignedArtwork(networkID: "thorchain", reference: "X/RUJI") == nil, "Non-EVM token references preserve case")
        let sui = catalog.examples(for: .sui).first!
        let suiReference = String(sui.id.dropFirst("sui:".count))
        check(catalog.redesignedArtwork(networkID: "sui", reference: suiReference.lowercased()) == nil,
              "Move module and type names remain case sensitive")
        let stellarUSDC = catalog.examples(for: .stellar).first { $0.symbol == "USDC" }!
        let usdcIssuer = "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN"
        check(catalog.redesignedArtwork(networkID: "stellar", reference: "USDC-" + usdcIssuer) == stellarUSDC.artwork,
              "Stellar USDC contract and issuer identity share the supplied design")
        check(catalog.redesignedArtwork(networkID: "stellar", reference: "FAKE-" + usdcIssuer) == nil,
              "Another asset from the same issuer cannot borrow the design")
        check(catalog.examples(for: .ethereum).first?.symbol == "USDT", "Ethereum examples")
        check(catalog.examples(for: .ethereum).contains { $0.id.lowercased() == "ethereum:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" }, "Ethereum USDC contract")
        check(catalog.examples(for: .tron).contains { $0.id == "tron:TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t" }, "TRON USDT contract")
        check(catalog.examples(for: .polkadot).map(\.id) == ["polkadot:assets:1337", "polkadot:assets:1984"], "Polkadot Asset Hub USDC and USDt")
        check(catalog.examples(for: .thorchain).contains { $0.id == "thorchain:x/ruji" }, "THORChain native token denomination")
        check(OathReceiveNetworkGuide(chain: .stellar).notice == .receiveTrustlineNotice, "Stellar trustline requirement")
        check(OathReceiveNetworkGuide(chain: .xrpl).notice == .receiveTrustlineNotice, "XRP Ledger trustline requirement")
        check(OathReceiveNetworkGuide(chain: .near).notice == .receiveRegistrationNotice, "NEAR registration requirement")
        for chain in OathImportChain.allCases {
            let guide = OathReceiveNetworkGuide(chain: chain)
            let expected: OathStringKey = chain == .bitcoin ? .bitcoinReceiveTracking
                : chain == .robinhood ? .receiveManualTracking
                : nativeOnly.contains(chain) ? .receiveNativeTracking
                : (chain.isEVM && chain != .arc) || chain == .solana || chain == .tron || chain == .ton || chain == .aptos || chain == .sui || chain == .near || chain == .xrpl || chain == .stellar || chain == .polkadot || chain == .thorchain ? .receiveIndexedTracking
                : chain.isEVM ? .receiveManualTracking : .receiveDeferredTracking
            check(guide.trackingExplanation == expected, "No unsupported auto-detection promise on \(chain.id)")
        }
        check(OathReceiveNetworkGuide(chain:.arc,arcIndexAvailable:true).trackingExplanation == .receiveIndexedTracking,
              "Arc indexed tracking requires configured archive access")
        check(OathReceiveNetworkGuide(chain:.robinhood,robinhoodIndexAvailable:true).trackingExplanation == .receiveIndexedTracking,
              "Robinhood describes indexed discovery only when its index is configured")
        check(OathReceiveExampleCatalog(networks: [:]).examples(for: .ethereum).isEmpty, "Optional catalog absence remains safe")
        check(OathReceiveExampleCatalog.load(from: nil).networks.isEmpty, "Missing bundle resource preserves receiving")
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: invalid) }
        try Data("invalid catalog".utf8).write(to: invalid)
        check(OathReceiveExampleCatalog.load(from: invalid).networks.isEmpty, "Invalid catalog preserves receiving")
        check(OathReceiveExampleCatalog.load(from: root.appendingPathComponent("OathApp/Resources/ReceiveAssets.json")).networks == catalog.networks,
              "Production loader reads the complete bundled catalog")

        // Public/synthetic payloads exercise the address character sets and
        // lengths used by the supported networks, not chain address validation.
        let payloads: [String] = [
            "0x" + String(repeating: "a3", count: 20),
            "0x" + String(repeating: "c4", count: 32),
            "bc1q" + String(repeating: "q", count: 38),
            "bitcoincash:q" + String(repeating: "p", count: 41),
            "D" + String(repeating: "a", count: 33),
            "ltc1q" + String(repeating: "q", count: 38),
            String(repeating: "e5", count: 32),
            "G" + String(repeating: "B", count: 55),
            "EQ" + String(repeating: "aB3_", count: 11) + "AB",
            "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
            "So11111111111111111111111111111111111111112",
            "r" + String(repeating: "P", count: 33)
        ]
        check(OathReceiveQRCode.image(for: "") == nil, "Empty addresses have no QR")
        for payload in payloads {
            let image = OathReceiveQRCode.image(for: payload)!
            check(image.width == image.height, "Square QR")
            check(image.width % 8 == 0, "Integer QR module scale")
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: image).perform([request])
            check(request.results?.contains { $0.payloadStringValue == payload } == true,
                  "Actual rendered QR decodes to the exact original address")
            // Verify the explicit quiet zone is opaque white, not theme-dependent.
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let whiteBorder = pixels.withUnsafeMutableBytes { bytes -> Bool in
                let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return (0..<image.width).allSatisfy { x in
                    (0..<4).allSatisfy { bytes[x * 4 + $0] == 255 }
                }
            }
            check(whiteBorder, "Opaque white QR quiet zone")
        }
        print("Passed \(checks) receive catalog, original-artwork, network-guidance and QR decoding checks.")
    }
}
