import Foundation
import XCTest
@testable import OathBitcoin

private actor FeeRequests {
    var hosts:[String]=[]
    func add(_ request:URLRequest) { hosts.append(request.url!.host!) }
}
final class BitcoinFeeFallbackTests:XCTestCase,@unchecked Sendable {
    func testHealthyElectrumDoesNotCallHTTP() async throws {
        let provider=BitcoinFeeFallback { _ in XCTFail("Unnecessary fallback");throw BitcoinSendError.feeUnavailable }
        let rate=try await provider.rate { 2345 };XCTAssertEqual(rate,2345)
    }
    func testMempoolRecoveryUsesRelayMinimumAndRoundsUp() async throws {
        let requests=FeeRequests()
        let provider=BitcoinFeeFallback { request in
            await requests.add(request)
            XCTAssertNil(request.httpBody);XCTAssertNil(request.url?.query)
            XCTAssertNil(request.value(forHTTPHeaderField:"Authorization"))
            return Data(#"{"halfHourFee":1.23401,"minimumFee":2.00001}"#.utf8)
        }
        let rate=try await provider.rate { throw BitcoinError.timeout };XCTAssertEqual(rate,2001)
        let hosts=await requests.hosts;XCTAssertEqual(hosts,["mempool.space"])
    }
    func testBadMempoolRotatesToBlockstreamAndCannotUseLongerTarget() async throws {
        let requests=FeeRequests()
        let provider=BitcoinFeeFallback { request in
            await requests.add(request)
            return Data((request.url!.host == "mempool.space" ? "{}":#"{"2":3.14101,"6":0.1}"#).utf8)
        }
        let rate=try await provider.rate { throw BitcoinSendError.feeUnavailable };XCTAssertEqual(rate,3142)
        let hosts=await requests.hosts;XCTAssertEqual(hosts,["mempool.space","blockstream.info"])
        XCTAssertThrowsError(try BitcoinFeeFallback.decode(Data(#"{"6":1}"#.utf8),source:.blockstream))
    }
    func testExcessiveZeroNegativeMalformedAndMissingQuotesAreRejected() throws {
        for text in [#"{"3":0}"#,#"{"3":-1}"#,#"{"3":1000.001}"#,#"{"3":"NaN"}"#,"{}","[]"] {
            XCTAssertThrowsError(try BitcoinFeeFallback.decode(Data(text.utf8),source:.blockstream))
        }
        XCTAssertEqual(try BitcoinFeeFallback.decode(Data(#"{"3":0.1}"#.utf8),source:.blockstream),1000)
    }
    func testCompleteOutageFailsInsteadOfInventingFee() async throws {
        let requests=FeeRequests()
        let provider=BitcoinFeeFallback { request in await requests.add(request);throw URLError(.timedOut) }
        do { _=try await provider.rate { throw BitcoinError.timeout };XCTFail() }
        catch { XCTAssertEqual(error as? BitcoinSendError,.feeUnavailable) }
        let calls=await requests.hosts.count;XCTAssertEqual(calls,2)
    }
    func testCancellationNeverStartsOrContinuesFallback() async throws {
        let requests=FeeRequests()
        let provider=BitcoinFeeFallback { request in await requests.add(request);throw CancellationError() }
        do { _=try await provider.rate { throw CancellationError() };XCTFail() } catch is CancellationError { }
        let before=await requests.hosts.count;XCTAssertEqual(before,0)
        do { _=try await provider.rate { throw BitcoinError.timeout };XCTFail() } catch is CancellationError { }
        let after=await requests.hosts.count;XCTAssertEqual(after,1)
    }
    func testLivePublicHTTPFeeSources() async throws {
        guard ProcessInfo.processInfo.environment["OATH_CHAIN_FALLBACK_LIVE"] == "1" else { throw XCTSkip("Opt-in read-only mainnet fees; no transaction submitted") }
        for source in BitcoinFeeFallback.Source.allCases {
            let (data,response)=try await URLSession.shared.data(for:URLRequest(url:source.url,timeoutInterval:10))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
            let rate=try BitcoinFeeFallback.decode(data,source:source)
            XCTAssertTrue(UTXONetwork.bitcoin.sendFeeRates.contains(rate))
        }
    }
}
