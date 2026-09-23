#if LIVE_MAINNET_TESTS
import Foundation
import Testing
@testable import Aperture

/// Opt-in, mainnet-only reads. These are public documentation/test fixtures;
/// no wallet is created, funded, signed, or modified.
@Suite(.serialized)
struct SolanaLiveBalanceVerificationTests {
    @Test(arguments: SolanaLiveReadEndpoint.allCases)
    func nativeAndEveryTokenProgramMatchTheRawMainnetResponse(provider: SolanaLiveReadEndpoint) async throws {
        let recorder = SolanaLiveResponseRecorder()
        let session = URLSession(configuration: .ephemeral)
        let transport = SolanaRPCTransport(endpoints: [provider.url], timeoutSeconds: 20) { request in
            let response = try await session.data(for: request)
            await recorder.record(request: request, data: response.0)
            return response
        }
        let client = SolanaAPIClient(transport: transport)
        let owners = [
            "D89hHJT5Aqyx1trP6EnGY9jJUB3whgnq3aUvvCqedvzf",
            "4Qkev8aNZcqFNSRhQzwyLMFSsi94jHqE8WNVTJzTP99F"
        ]
        for owner in owners {
            let material = SolanaAccountMaterial(kind: .trustWallet, address: owner,
                publicKey: "public-mainnet-fixture", derivationPath: nil)
            let started = ContinuousClock.now
            let snapshot = try await client.loadBalanceSnapshot(
                accounts: .init(primary: material, alternatives: []), historyCursors: [:]
            )
            let elapsed = started.duration(to: .now)
            let records = await recorder.take()
            let requests = try records.flatMap { record in
                try JSONSerialization.jsonObject(with: record.request) as! [[String: Any]]
            }
            #expect(requests.count == 3)
            #expect(requests.filter { $0["method"] as? String == "getBalance" }.count == 1)
            #expect(requests.filter { $0["method"] as? String == "getTokenAccountsByOwner" }.count == 2)

            let responses = try records.flatMap { record in
                try JSONSerialization.jsonObject(with: record.response) as! [[String: Any]]
            }
            let native = try #require(responses.first { $0["id"] as? Int == 1 }?["result"] as? [String: Any])
            let nativeValue = try #require(native["value"] as? NSNumber)
            #expect(snapshot.solAtomicBalance == nativeValue.stringValue)
            var expected: [String: (amount: UInt64, decimals: Int)] = [:]
            var originalCount = 0
            var extendedCount = 0
            for response in responses where response["id"] as? Int != 1 {
                let result = try #require(response["result"] as? [String: Any])
                let rows = try #require(result["value"] as? [[String: Any]])
                if response["id"] as? Int == 2 { originalCount = rows.count } else { extendedCount = rows.count }
                for row in rows {
                    let account = try #require(row["account"] as? [String: Any])
                    let data = try #require(account["data"] as? [String: Any])
                    let parsed = try #require(data["parsed"] as? [String: Any])
                    let info = try #require(parsed["info"] as? [String: Any])
                    #expect(info["owner"] as? String == owner)
                    let mint = try #require(info["mint"] as? String)
                    let amount = try #require(info["tokenAmount"] as? [String: Any])
                    let amountText = try #require(amount["amount"] as? String)
                    let raw = try #require(UInt64(amountText))
                    let decimals = try #require(amount["decimals"] as? Int)
                    let previous = expected[mint]?.amount ?? 0
                    let (sum, overflow) = previous.addingReportingOverflow(raw)
                    #expect(!overflow)
                    expected[mint] = (sum, decimals)
                }
            }
            #expect(snapshot.spendable.balanceAuthority.isComplete)
            #expect(snapshot.tokens.count == expected.count)
            for token in snapshot.tokens {
                let value = try #require(expected[token.mint])
                #expect(token.atomicAmount == String(value.amount))
                #expect(token.decimals == value.decimals)
            }
            if owner == owners[0] {
                #expect(originalCount > 0)
                #expect(extendedCount > 0)
            }
            print("[SolanaReadVerification] provider=\(provider.rawValue) methods=3 SPL=\(originalCount) Token2022=\(extendedCount) exactMints=\(expected.count) elapsed=\(elapsed)")
        }
    }
}

enum SolanaLiveReadEndpoint: String, CaseIterable, Sendable {
    case official, ankrProxy
    var url: URL {
        switch self {
        case .official: URL(string: "https://api.mainnet-beta.solana.com")!
        case .ankrProxy: URL(string: "https://aperture-notifications.devdas98x.workers.dev/v1/provider/ankr/solana/jsonrpc")!
        }
    }
}

private actor SolanaLiveResponseRecorder {
    struct Record: Sendable {
        let request: Data
        let response: Data
    }
    private var records: [Record] = []
    func record(request: URLRequest, data: Data) {
        if let body = request.httpBody { records.append(.init(request: body, response: data)) }
    }
    func take() -> [Record] { defer { records = [] }; return records }
}
#endif
