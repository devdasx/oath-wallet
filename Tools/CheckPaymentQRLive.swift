import Foundation
import ImageIO
import UniformTypeIdentifiers
import OathAnkr

/// Explicit opt-in devnet test. Fixture secrets stay outside the repository.
@main struct CheckPaymentQRLive {
    struct Fixture: Decodable { let network: String, sender: String, recipient: String, seed: String }
    enum Failure: Error { case validation }
    static func main() async {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            guard let path = ProcessInfo.processInfo.environment["OATH_SOLANA_TESTNET_FIXTURE"] else { throw Failure.validation }
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard fixture.network == "devnet" else { throw Failure.validation }
            let configuration = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("OathApp/Private/TokenRPC.plist")), format: nil) as? [String: Any]
            guard let key = configuration?["AnkrAPIKey"] as? String else { throw Failure.validation }
            let client = try SolanaSendClient(network: .devnet, apiKey: key)
            let reference = try SolanaSendCrypto.address(privateKey: Data(repeating: 87, count: 32))
            let payload = "solana:" + fixture.recipient + "?amount=0.000001&reference=" + reference + "&memo=OathQRTest&label=Test&message=Devnet%20only"
            guard let image = OathReceiveQRCode.image(for: payload) else { throw Failure.validation }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { throw Failure.validation }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination), let decoded = try OathScanImage.codes(in: png as Data).first,
                  case .recipient(let request) = OathScanParser(validator: nil, evmNetworks: [:]).parse(decoded),
                  request.amount == "0.000001", request.memo == "OathQRTest", request.solanaReferences == [reference],
                  request.displayNote == "Test\nDevnet only", let address = request.decoded(on: .solana)?.address else { throw Failure.validation }
            let plan = try await client.quote(sender: fixture.sender, recipient: address, reference: "native", decimals: 9,
                amount: "1000", memo: request.memo ?? "", paymentReferences: request.solanaReferences)
            var secret = try TronIdentity.hex(fixture.seed); defer { secret.resetBytes(in: 0..<secret.count) }
            let signed = try SolanaSendCrypto.sign(plan, privateKey: secret)
            _ = try await client.submit(signed, plan: plan, reconcileFirst: false)
            var outcome = SolanaSendReceipt.Outcome.unknown
            for _ in 0..<45 {
                outcome = try await client.walletConnectStatus(signed.hash)
                if outcome == .confirmed || outcome == .failed { break }
                try await Task.sleep(for: .seconds(2))
            }
            guard outcome == .confirmed else { throw Failure.validation }
            // Inspect the network's decoded instruction, not only locally built bytes.
            var rpc = URLRequest(url: URL(string: "https://rpc.ankr.com/solana_devnet/")!.appendingPathComponent(key))
            rpc.httpMethod = "POST"; rpc.timeoutInterval = 20; rpc.setValue("application/json", forHTTPHeaderField: "Content-Type")
            rpc.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "getTransaction",
                "params": [signed.hash, ["encoding": "json", "commitment": "confirmed", "maxSupportedTransactionVersion": 0]]])
            let (data, response) = try await URLSession.shared.data(for: rpc)
            let json = try JSONDecoder().decode(SolanaJSON.self, from: data)["result"]
            guard (response as? HTTPURLResponse)?.statusCode == 200, json["meta"]["err"].isNull,
                  let keys = json["transaction"]["message"]["accountKeys"].array?.compactMap(\.string),
                  let instructions = json["transaction"]["message"]["instructions"].array,
                  let transfer = instructions.last, let indices = transfer["accounts"].array?.compactMap(\.integer),
                  let referenceIndex = indices.last, referenceIndex < keys.count, keys[Int(referenceIndex)] == reference,
                  let recipientIndex = keys.firstIndex(of: address),
                  let before = json["meta"]["preBalances"].array?[recipientIndex].integer,
                  let after = json["meta"]["postBalances"].array?[recipientIndex].integer, after == before + 1000,
                  instructions.count >= 2, let memo = instructions[instructions.count - 2]["data"].string,
                  try SolanaSendCrypto.decode(memo) == Data("OathQRTest".utf8) else { throw Failure.validation }
            let report: [String: Any] = ["network": "devnet", "signature": signed.hash, "confirmed": true,
                "receivedAtomic": "1000", "memoVerifiedOnChain": true, "referenceVerifiedOnChain": true,
                "layer": "production QR image decoder, parser, quote and signer; paid Ankr; no app UI", "testedAt": ISO8601DateFormatter().string(from: .now)]
            let output = root.appendingPathComponent("output/payment-qr-solana-live.json")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
            print("PASS real devnet QR payment: amount, memo and merchant reference verified on chain. " + signed.hash)
        } catch {
            print("Payment QR live check failed: " + ((error as? SolanaSendError).map { String(describing: $0) } ?? "validation"))
            exit(1)
        }
    }
}
