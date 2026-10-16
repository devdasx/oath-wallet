import Foundation
import CryptoKit
import ImageIO
import Vision

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
        let tokenChains = Set(OathImportChain.allCases).subtracting(nativeOnly)
        // The four newly indexed networks use the existing explanation-only
        // fallback until a curated, verified illustration catalog is supplied.
        // Never copy another chain's contracts or invent token logos.
        let newIndexed: Set<OathImportChain> = [.fantom,.flare,.somnia,.story,.robinhood]
        let illustrated = tokenChains.subtracting(newIndexed)
        check(Set(catalog.networks.keys) == Set(illustrated.map(\.id)), "Existing curated token-network coverage")
        check(sources.count == 220, "Ten network-specific examples on each of 22 token networks")

        for chain in OathImportChain.allCases {
            let guide = OathReceiveNetworkGuide(chain: chain)
            let examples = catalog.examples(for: chain)
            check(guide.supportsTokens == !nativeOnly.contains(chain), "Receiving capability for \(chain.id)")
            check(examples.count == (illustrated.contains(chain) ? 10 : 0), "Verified examples or explanation fallback for \(chain.id)")
            check(Set(examples.map(\.id)).count == examples.count, "Unique contract identities within \(chain.id)")
            for example in examples {
                check(example.id.hasPrefix(chain.id + ":"), "Never reuse another network's token entry")
                check(!example.name.isEmpty && !example.symbol.isEmpty, "Accessible token identity")
                let source = sources.first { $0["id"] as? String == example.id }!
                check(source["network"] as? String == chain.id, "Catalog matches source network")
                check(source["artwork"] as? String == example.artwork, "Catalog matches source logo")
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
        check(catalog.examples(for: .ethereum).first?.symbol == "USDT", "Ethereum examples")
        check(catalog.examples(for: .ethereum).contains { $0.id.lowercased() == "ethereum:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" }, "Ethereum USDC contract")
        check(catalog.examples(for: .tron).contains { $0.id == "tron:TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t" }, "TRON USDT contract")
        check(OathReceiveNetworkGuide(chain: .stellar).notice == .receiveTrustlineNotice, "Stellar trustline requirement")
        check(OathReceiveNetworkGuide(chain: .xrpl).notice == .receiveTrustlineNotice, "XRP Ledger trustline requirement")
        check(OathReceiveNetworkGuide(chain: .near).notice == .receiveRegistrationNotice, "NEAR registration requirement")
        for chain in OathImportChain.allCases {
            let guide = OathReceiveNetworkGuide(chain: chain)
            let expected: OathStringKey = chain == .bitcoin ? .bitcoinReceiveTracking
                : chain == .robinhood ? .receiveManualTracking
                : nativeOnly.contains(chain) ? .receiveNativeTracking
                : (chain.isEVM && chain != .arc) || chain == .solana || chain == .tron || chain == .ton || chain == .aptos || chain == .sui || chain == .near || chain == .xrpl || chain == .stellar ? .receiveIndexedTracking
                : chain.isEVM ? .receiveManualTracking : .receiveDeferredTracking
            check(guide.trackingExplanation == expected, "No unsupported auto-detection promise on \(chain.id)")
        }
        check(OathReceiveNetworkGuide(chain:.arc,arcIndexAvailable:true).trackingExplanation == .receiveIndexedTracking,
              "Arc indexed tracking requires configured archive access")
        check(OathReceiveNetworkGuide(chain:.robinhood,robinhoodIndexAvailable:true).trackingExplanation == .receiveIndexedTracking,
              "Robinhood describes indexed discovery only when its index is configured")
        check(OathReceiveExampleCatalog(networks: [:]).examples(for: .ethereum).isEmpty, "Optional catalog absence remains safe")

        // Public/synthetic payloads exercise the address character sets and
        // lengths used by all 26 networks, not chain address validation.
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
