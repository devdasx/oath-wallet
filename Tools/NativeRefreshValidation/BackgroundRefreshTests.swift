import XCTest
@testable import RefreshActionCore

@MainActor final class BackgroundRefreshTests: XCTestCase {
    func testRepeatedPullReusesWorkAndCancellationInvalidatesLateCompletion() async throws {
        let owner = BackgroundRefresh()
        let firstStarted = expectation(description: "first action started")
        let firstReturned = expectation(description: "old callback returned")
        let staleCompletion = expectation(description: "cancelled owner delivered a late result")
        staleCompletion.isInverted = true
        let replacementFinished = expectation(description: "replacement finished")
        var release: CheckedContinuation<Void, Never>?
        var starts = 0
        var outcomes = [RefreshAction.Outcome]()
        let initial = try await owner.present(action: {
            starts += 1
            await withCheckedContinuation { release = $0; firstStarted.fulfill() }
            firstReturned.fulfill()
        }, onCompletion: { outcomes.append($0); staleCompletion.fulfill() }, wait: { _ in })
        XCTAssertNil(initial)
        await fulfillment(of: [firstStarted], timeout: 5)
        _ = try await owner.present(action: { XCTFail("Duplicate action started") },
                                    onCompletion: { _ in XCTFail("Duplicate completion") }, wait: { _ in })
        owner.cancel()
        _ = try await owner.present(action: { starts += 1 }, onCompletion: {
            outcomes.append($0)
            replacementFinished.fulfill()
        }, wait: { _ in })
        await fulfillment(of: [replacementFinished], timeout: 5)
        release?.resume()
        await fulfillment(of: [firstReturned], timeout: 5)
        await fulfillment(of: [staleCompletion], timeout: 0.2)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(outcomes, [.succeeded])
        XCTAssertEqual(owner.outcome, .succeeded)
    }
}
