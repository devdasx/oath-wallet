import Foundation
import XCTest
@testable import OathDiagnostics

final class RuntimeStackRegressionTests: XCTestCase {
    func testNestedMetricKitStackKeepsAppFramesBeyondSystemAbortFrames() throws {
        let appUUID = "00000000-0000-0000-0000-000000000123"
        var frame: [String: Any] = ["binaryName": "OathAtmosphere", "binaryUUID": appUUID,
                                    "offsetIntoBinaryTextSegment": 424242,
                                    "applicationSpecificInformation": "private fixture input"]
        for index in (0..<30).reversed() {
            frame = ["binaryName": "UIKitCore", "offsetIntoBinaryTextSegment": index,
                     "subFrames": [frame]]
        }
        let raw = try JSONSerialization.data(withJSONObject: ["diagnosticMetaData": ["signal": 6],
            "callStackTree": ["callStacks": [["threadAttributed": true, "callStackRootFrames": [frame]]]]])
        let safe = DiagnosticPrivacy.runtime(String(decoding: raw, as: UTF8.self))
        XCTAssertTrue(safe.contains(appUUID)); XCTAssertTrue(safe.contains("424242"))
        XCTAssertFalse(safe.contains("private fixture input"))
        XCTAssertFalse(safe.contains("depth limited"))
        XCTAssertLessThanOrEqual(safe.utf8.count, 14 * 1024)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(safe.utf8)))
    }
    func testRefilteringPreservesTruncationAndStillRejectsPrivateFields() throws {
        let raw = #"{"_truncated":true,"diagnosticMetaData":{"signal":6},"password":"private fixture"}"#
        let once = DiagnosticPrivacy.runtime(raw)
        let twice = DiagnosticPrivacy.runtime(once)
        XCTAssertEqual(once, twice)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(twice.utf8)) as? [String: Any])
        XCTAssertEqual(value["_truncated"] as? Bool, true)
        XCTAssertNil(value["password"])
    }
    func testAdversarialDepthRemainsBoundedAndValidJSON() throws {
        var frame: [String: Any] = ["binaryName": "fixture"]
        for _ in 0..<150 { frame = ["subFrames": [frame]] }
        let raw = try JSONSerialization.data(withJSONObject: ["callStackTree": frame])
        let safe = DiagnosticPrivacy.runtime(String(decoding: raw, as: UTF8.self))
        XCTAssertLessThanOrEqual(safe.utf8.count, 14 * 1024)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any])
        XCTAssertEqual(value["_truncated"] as? Bool, true)
    }
}
