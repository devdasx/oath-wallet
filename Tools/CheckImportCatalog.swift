import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

@main struct CheckImportCatalog {
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            count += 1
        }

        let expected = Set([
            "Aptos", "Arbitrum", "Arc", "Avalanche C-Chain", "Base", "Bitcoin", "Bitcoin Cash",
            "BNB Smart Chain", "Dogecoin", "Ethereum", "Fantom", "Flare", "Somnia", "Story", "Gnosis", "Linea", "Litecoin", "NEAR Protocol",
            "Optimism", "Polygon", "Scroll", "Solana", "Stellar", "Sui Network", "Taiko", "Telos",
            "Gram", "TRON", "X Layer", "XRP Ledger"
        ])
        let choices = OathPrivateKeyChoice.all
        let networks = choices.flatMap(\.networks)
        check(Set(networks.map(\.name)) == expected, "Every requested chain must appear")
        check(networks.count == expected.count, "A network must never appear in multiple choices")
        check(Set(choices.map(\.id)).count == choices.count, "Selection identities must be unique")
        check(choices.count == 13, "One EVM group and twelve individual imports")
        check(OathPrivateKeyChoice.evm.networks.count == 18, "The EVM group covers eighteen networks")
        check(!OathPrivateKeyChoice.evm.networks.contains(.tron), "TRON uses its own import path")
        check(!OathPrivateKeyChoice.evm.networks.contains(.near), "NEAR must not be mistaken for Aurora EVM")
        check(!OathPrivateKeyChoice.evm.networks.contains(.bitcoin), "Bitcoin requires its own import")
        check(OathPrivateKeyChoice.evm.networks.contains(.avalanche), "The requested Avalanche network is C-Chain")
        let preview = OathPrivateKeyChoice.evm.logoPreviewNetworks
        check(preview.count == 5, "The EVM row previews five logos")
        check(Set(preview).count == preview.count, "Preview logos must be unique")
        check(preview.allSatisfy(OathPrivateKeyChoice.evm.networks.contains), "Preview only supported networks")
        check(preview.count + OathPrivateKeyChoice.evm.additionalNetworkCount == 18,
              "The remainder must account for every network without changing group membership")
        for network in networks {
            let found = OathPrivateKeyChoice.matching(network.name)
            check(found.contains { $0.networks.contains(network) }, "Each chain name must find its import choice")
            if network.isEVM {
                check(found == [.evm], "Searching an EVM member must select its single shared group")
            }
        }
        check(OathPrivateKeyChoice.matching("  \n ") == choices, "Whitespace resets search")
        check(OathPrivateKeyChoice.matching("aRbItRuM") == [.evm], "Search ignores case")
        check(OathPrivateKeyChoice.matching("BSC") == [.evm], "BNB's common name finds the group")
        check(OathPrivateKeyChoice.matching("MATIC") == [.evm], "Polygon's old ticker finds the group")
        check(OathPrivateKeyChoice.matching("TRX").map(\.id) == ["tron"], "TRON ticker stays separate")
        check(OathPrivateKeyChoice.matching("XLM").map(\.id) == ["stellar"], "Stellar ticker finds Stellar")
        check(OathPrivateKeyChoice.matching("XRP").map(\.id) == ["xrpl"], "XRP finds the ledger")
        for alias in ["Gram", "GRAM", "TON", "Toncoin", "The Open Network"] {
            check(OathPrivateKeyChoice.matching(alias).map(\.id) == ["ton"], "Current and legacy names find the same wallet network")
        }
        check(OathImportChain.ton.id == "ton", "Branding must preserve stored wallet identity")
        check(OathPrivateKeyChoice.matching("Ethereum Polygon").isEmpty, "Do not combine words from unrelated networks")
        check(OathPrivateKeyChoice.matching("not-a-supported-chain").isEmpty, "Unknown search has an empty state")

        // Asset inventory only: no network, simulator, wallet data, or Keychain.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("Design/NetworkLogos/manifest.json"))) as! [[String: Any]]
        for chain in OathImportChain.allCases {
            let folder = root.appendingPathComponent("OathApp/Assets.xcassets/Networks/\(chain.logoAsset).imageset")
            let contents = try Data(contentsOf: folder.appendingPathComponent("Contents.json"))
            let json = try JSONSerialization.jsonObject(with: contents) as! [String: Any]
            let properties = json["properties"] as! [String: Any]
            check(properties["template-rendering-intent"] as? String == "original", "Keep authentic logo colors")
            let images = json["images"] as! [[String: Any]]
            check(images.count == 1, "Each network has one canonical artwork source")
            let image = images[0]["filename"] as! String
            let data = try Data(contentsOf: folder.appendingPathComponent(image))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let entry = manifest.first { $0["id"] as? String == chain.id }
            check(entry?["assetSHA256"] as? String == hash, "Bundled artwork matches its source manifest")
            switch folder.appendingPathComponent(image).pathExtension {
            case "pdf":
                check(properties["preserves-vector-representation"] as? Bool == true, "Retain vector quality")
                check(CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init)?.numberOfPages == 1,
                      "A PDF logo must decode to one page")
            case "svg":
                check(properties["preserves-vector-representation"] as? Bool == true, "Retain the supplied SVG")
                check(String(data: data, encoding: .utf8)?.contains("<svg") == true, "The SVG source is present")
            default:
                let source = CGImageSourceCreateWithData(data as CFData, nil)
                let raster = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                check(raster != nil, "Raster logo must decode")
                check((raster?.width ?? 0) >= 108 && (raster?.height ?? 0) >= 108,
                      "Supplied artwork covers the largest 36-point badge at 3x")
            }
        }
        print("Passed \(count) catalog, search, grouping, and artwork checks.")
    }
}
