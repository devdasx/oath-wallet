import XCTest
import OathDatabase
@testable import OathMarketData

/// Opt-in public, read-only API validation. No wallet/account data or signing.
@MainActor final class ContractPriceLiveTests: XCTestCase {
    struct Sample: Codable, Sendable { let networkID:String; let reference:String; let decimals:Int; let symbol:String }
    struct Result: Codable, Sendable { let networkID:String; let reference:String; let symbol:String; let usd:String?; let source:String?; let timestamp:Double?; let error:String? }
    func testLiveContractPrices() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_TOKEN_PRICES"] == "1" else { throw XCTSkip("Opt-in public API test") }
        let environment = ProcessInfo.processInfo.environment
        let input = URL(fileURLWithPath:try XCTUnwrap(environment["OATH_PRICE_SAMPLES"]))
        var samples = try JSONDecoder().decode([Sample].self,from:Data(contentsOf:input))
        samples.insert(.init(networkID:"ethereum",reference:"0x720cd16b011b987da3518fbf38c3071d4f0d1495",decimals:8,symbol:"FLUX"),at:0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oath-price-live-"+UUID().uuidString)
        let db = try await OathDatabase.open(at:directory.appendingPathComponent("test.sqlite"))
        let networks = Set(samples.map(\.networkID)).sorted().enumerated().map { index,network in
            NetworkRecord(id:network,name:network,family:"fixture",symbol:"NATIVE",decimals:18,derivationPath:"fixture",logo:"",sortOrder:index)
        }
        let assets = samples.map { AssetRecord(id:$0.networkID+":"+$0.reference,networkID:$0.networkID,reference:$0.reference,name:$0.symbol,symbol:$0.symbol,decimals:$0.decimals) }
        try await db.seed(networks:networks,assets:assets)
        let service = MarketDataService(database:db)
        var results:[Result] = []
        // Bounded callers, with provider-level coalescing and quota pacing.
        for sample in samples {
            let asset = MarketAsset(id:sample.networkID+":"+sample.reference,networkID:sample.networkID,reference:sample.reference,decimals:sample.decimals)
            do {
                let quote = try await service.quote(for:asset)
                let stored = try await db.latestPrice(assetID:asset.id,currency:"USD")
                XCTAssertEqual(stored?.value,quote.value.usd)
                XCTAssertGreaterThan(quote.value.decimal ?? 0,0)
                results.append(.init(networkID:sample.networkID,reference:sample.reference,symbol:sample.symbol,usd:quote.value.usd,source:stored?.source,timestamp:quote.fetchedAt.timeIntervalSince1970,error:nil))
                print("PRICE_LIVE \(sample.networkID) \(sample.symbol) \(stored?.source ?? "unknown") \(quote.value.usd)")
            } catch {
                results.append(.init(networkID:sample.networkID,reference:sample.reference,symbol:sample.symbol,usd:nil,source:nil,timestamp:nil,error:String(describing:error)))
                print("PRICE_LIVE \(sample.networkID) \(sample.symbol) unavailable \(error)")
            }
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        if let path=environment["OATH_PRICE_REPORT"] { try encoder.encode(results).write(to:URL(fileURLWithPath:path),options:.atomic) }
        for (network,symbol) in [("ethereum","FLUX"),("ethereum","USDC"),("solana","USDC"),("tron","USDT")] {
            XCTAssertTrue(results.contains{$0.networkID==network && $0.symbol==symbol && $0.usd != nil},"Missing live price: \(network) \(symbol)")
        }
    }
}

extension ContractPriceLiveTests {
    func testLiveProviderCoverageForUnresolvedTokens() async throws {
        let env=ProcessInfo.processInfo.environment
        guard env["OATH_PRICE_PROVIDER_PROBE"] == "1" else { throw XCTSkip("Opt-in coverage investigation") }
        let input=URL(fileURLWithPath:try XCTUnwrap(env["OATH_PRICE_SAMPLES"]))
        let samples=try JSONDecoder().decode([Sample].self,from:Data(contentsOf:input))
        let transport=URLSessionMarketTransport()
        var rows:[[String:String]]=[]
        for sample in samples {
            let asset=MarketAsset(id:sample.networkID+":"+sample.reference,networkID:sample.networkID,reference:sample.reference,decimals:sample.decimals)
            for request in ContractPriceRequest.requests(for:asset) {
                var row=["network":sample.networkID,"symbol":sample.symbol,"reference":sample.reference,"provider":request.provider.rawValue]
                do {
                    let data=try await transport.data(from:request.url)
                    let value=try ContractPriceDecoding.decode(data,request:request,asset:asset,now:.now)
                    row["usd"]=value.quote.usd
                } catch { row["error"]=String(describing:error) }
                rows.append(row)
                FileHandle.standardOutput.write(Data("PRICE_PROVIDER \(sample.networkID) \(sample.symbol) \(request.provider.rawValue) \(row["usd"] ?? row["error"] ?? "unknown")\n".utf8))
            }
        }
        if let path=env["OATH_PRICE_REPORT"] { try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path),options:.atomic) }
    }

    func testLiveNativePrices() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_NATIVE_PRICES"] == "1" else { throw XCTSkip("Opt-in native quote validation") }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("native-price-live-"+UUID().uuidString)
        let db=try await OathDatabase.open(at:directory.appendingPathComponent("test.sqlite"))
        let networks=MarketIdentity.native.sorted{$0.key<$1.key}
        try await db.seed(networks:networks.enumerated().map{index,pair in
            .init(id:pair.key,name:pair.key,family:"fixture",symbol:pair.value.coinbase,decimals:18,derivationPath:"fixture",logo:"",sortOrder:index)
        },assets:networks.map{.init(id:$0.key+":native",networkID:$0.key,reference:"native",name:$0.key,symbol:$0.value.coinbase,decimals:18)})
        let service=MarketDataService(database:db)
        var results:[Result]=[]
        for (network,mapping) in networks {
            let asset=MarketAsset(id:network+":native",networkID:network,reference:"native",decimals:18)
            do {
                let quote=try await service.quote(for:asset)
                let price=try await db.latestPrice(assetID:asset.id,currency:"USD")
                XCTAssertGreaterThan(quote.value.decimal ?? 0,0)
                XCTAssertEqual(quote.value.code,mapping.coinbase)
                results.append(.init(networkID:network,reference:"native",symbol:mapping.coinbase,usd:quote.value.usd,source:price?.source,timestamp:quote.fetchedAt.timeIntervalSince1970,error:nil))
            } catch {
                results.append(.init(networkID:network,reference:"native",symbol:mapping.coinbase,usd:nil,source:nil,timestamp:nil,error:String(describing:error)))
            }
        }
        if let path=ProcessInfo.processInfo.environment["OATH_PRICE_REPORT"] { let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(results).write(to:URL(fileURLWithPath:path),options:.atomic) }
        XCTAssertEqual(results.filter{$0.usd != nil}.count,networks.count,"All configured native identities must resolve")
    }
}
