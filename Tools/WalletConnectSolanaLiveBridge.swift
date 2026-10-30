import Foundation
import OathAnkr

struct Input: Decodable {
    let keyFile: String, chain: String, method: String, params: SolanaJSON
    var rejectWrongCluster: Bool? = nil
    var probeValidity: Bool? = nil
    var signature: String? = nil
}
struct Fixture: Decodable { let seed: String, sender: String }
@main struct Bridge {
    static func main() async {
        do {
            let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
            guard let network = SolanaSendNetwork(walletConnectChain: input.chain), network != .mainnet else { throw SolanaSendError.wrongNetwork }
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: input.keyFile)))
            let request = try WalletConnectSolanaRequest(method: input.method, chain: input.chain, account: fixture.sender, params: JSONEncoder().encode(input.params))
            let client = try SolanaSendClient(network: network,
                apiKey: network == .devnet ? ProcessInfo.processInfo.environment["OATH_SOLANA_ANKR_KEY"] : nil)
            if input.probeValidity == true {
                guard let transaction = request.transactions.first else { throw SolanaSendError.malformed }
                var result: [String: SolanaJSON] = ["valid": .bool(try await client.walletConnectTransactionValid(transaction, finalized: true))]
                if let signature = input.signature { result["outcome"] = .string(try await client.walletConnectStatus(signature).rawValue) }
                print(String(decoding: try JSONEncoder().encode(SolanaJSON.object(result)), as: UTF8.self)); return
            }
            let reviews: [WalletConnectSolanaReview]
            do { reviews = try await client.walletConnectReview(request) }
            catch SolanaSendError.expired where input.rejectWrongCluster == true {
                print("{\"rejectedWrongCluster\":true}"); return
            }
            guard input.rejectWrongCluster != true else { throw SolanaSendError.wrongNetwork }
            var key = try TronIdentity.hex(fixture.seed); defer { key.resetBytes(in: 0..<key.count) }
            let signed = try request.sign(privateKey: key)
            var result: [String: SolanaJSON] = ["result": signed.response,
                "reviews": .number(String(reviews.count)), "changes": .number(String(reviews.reduce(0) { $0 + $1.changes.count }))]
            if request.broadcasts {
                let signature = try await client.walletConnectSubmit(signed.transactions[0], request: request)
                var outcome = SolanaSendReceipt.Outcome.accepted
                for _ in 0..<45 {
                    outcome = try await client.walletConnectStatus(signature)
                    if outcome == .confirmed || outcome == .failed { break }
                    try await Task.sleep(for: .seconds(2))
                }
                guard outcome == .confirmed else { throw SolanaSendError.execution }
                result["signature"] = .string(signature); result["confirmed"] = .bool(true)
            }
            print(String(decoding: try JSONEncoder().encode(SolanaJSON.object(result)), as: UTF8.self))
        } catch {
            // No raw request, signed bytes, seed, provider body or credential output.
            let category = error as? SolanaSendError
            let safe = category.map { String(describing: $0) } ?? "bridge_failure"
            FileHandle.standardError.write(Data((safe + "\n").utf8)); exit(1)
        }
    }
}
