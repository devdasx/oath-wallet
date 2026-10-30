import Foundation
import XCTest
@testable import OathAnkr

/// Opt-in read-only reproduction using a disposable simulator test account.
@MainActor final class SimulatorHistoryLiveTests: XCTestCase {
    func testCeloAndMonadHistoryFromDisposableFixture() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["OATH_HISTORY_ANKR"], let owner = env["OATH_HISTORY_FIXTURE_OWNER"] else {
            throw XCTSkip("Opt-in disposable fixture history reads")
        }
        for chain in [IndexedEVMChain.celo, .monad] {
            let client = try IndexedEVMClient(chain: chain, apiKey: key, alchemyAPIKey: env["OATH_HISTORY_EXISTING_INDEX_KEY"])
            for stream in chain.historyStreams {
                var cursor: String?
                for pageNumber in 0..<3 {
                do {
                    let page = try await client.history(owner: owner, stream: stream, cursor: cursor)
                    print("HISTORY_FIXTURE chain=\(chain.rawValue) stream=\(stream.rawValue) page=\(pageNumber) events=\(page.events.count) next=\(page.next != nil)")
                    guard let next = page.next else { break }
                    cursor = next
                } catch {
                    XCTFail("History failed chain=\(chain.rawValue) stream=\(stream.rawValue) page=\(pageNumber) error=\(type(of: error))")
                    break
                }
                }
            }
        }
    }
}
