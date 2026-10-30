import Foundation
import XCTest
@testable import OathDiagnostics

final class RuntimeStackRegressionTests: XCTestCase {
    func testLargeAttributedStackKeepsItsAttributionWhenCompacted() throws {
        let frames = Array(repeating: ["binaryName": String(repeating: "UIKitCore.", count: 50),
            "binaryUUID": "00000000-0000-0000-0000-000000000123", "offsetIntoBinaryTextSegment": 42] as [String: Any], count: 128)
        let raw = try JSONSerialization.data(withJSONObject: ["diagnosticMetaData": ["signal": 6],
            "callStackTree": ["callStacks": [["threadAttributed": true, "callStackRootFrames": frames]]]])
        let safe = DiagnosticPrivacy.runtime(String(decoding: raw, as: UTF8.self))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any])
        let tree = try XCTUnwrap(report["callStackTree"] as? [String: Any])
        let stacks = try XCTUnwrap(tree["callStacks"] as? [[String: Any]])
        XCTAssertEqual(stacks.first?["threadAttributed"] as? Bool, true)
        XCTAssertEqual(report["_truncated"] as? Bool, true)
        XCTAssertLessThanOrEqual(safe.utf8.count, 14 * 1024)
        XCTAssertEqual(DiagnosticPrivacy.runtime(safe), safe)
    }

    func testLargeStackTreeCannotConsumeDiagnosticMetadataBudget() throws {
        let uuid = "00000000-0000-0000-0000-000000000321"
        let frames = (0..<128).map { index -> [String: Any] in
            ["binaryUUID": uuid, "offsetIntoBinaryTextSegment": index,
             "address": index, "sampleCount": 1, "threadNumber": index]
        }
        let stacks = (0..<32).map { _ -> [String: Any] in
            ["threadAttributed": false, "callStackRootFrames": frames]
        }
        // Dictionary traversal order is deliberately unspecified. Recreate
        // reports with distinct metadata so neither parse order nor a lucky
        // hash layout can become part of the metadata-retention contract.
        for build in 1...16 {
            let metadata: [String: Any] = ["signal": 6, "exceptionType": 1,
                "appBuildVersion": String(build), "appVersion": "4.0.3",
                "platformArchitecture": "arm64", "applicationSpecificInformation": "private fixture"]
            let raw = try JSONSerialization.data(withJSONObject: [
                "callStackTree": ["callStacks": stacks], "diagnosticMetaData": metadata,
                "password": "private fixture"
            ], options: [.sortedKeys])
            let safe = DiagnosticPrivacy.runtime(String(decoding: raw, as: UTF8.self))
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any])
            let saved = try XCTUnwrap(report["diagnosticMetaData"] as? [String: Any],
                "A large call tree must not replace essential metadata with a budget marker")
            XCTAssertEqual(saved["signal"] as? Int, 6)
            XCTAssertEqual(saved["exceptionType"] as? Int, 1)
            XCTAssertEqual(saved["appBuildVersion"] as? String, String(build))
            XCTAssertEqual(saved["appVersion"] as? String, "4.0.3")
            XCTAssertEqual(saved["platformArchitecture"] as? String, "arm64")
            XCTAssertEqual(report["_truncated"] as? Bool, true)
            XCTAssertFalse(safe.contains("private fixture"))
            XCTAssertLessThanOrEqual(safe.utf8.count, 14 * 1024)
            XCTAssertEqual(DiagnosticPrivacy.runtime(safe), safe)
        }
    }

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
    func testLargeFirstStackCannotEraseOtherAttributedStacks() throws {
        let firstUUID = "00000000-0000-0000-0000-000000000111"
        let secondUUID = "00000000-0000-0000-0000-000000000222"
        let wide = Array(repeating: ["binaryUUID": firstUUID,
            "offsetIntoBinaryTextSegment": 100, "binaryName": String(repeating: "System.", count: 60)] as [String: Any], count: 128)
        let raw = try JSONSerialization.data(withJSONObject: [
            "callStackTree": ["callStacks": [
                ["threadAttributed": true, "callStackRootFrames": wide],
                ["threadAttributed": true, "callStackRootFrames": [["binaryUUID": secondUUID,
                    "offsetIntoBinaryTextSegment": 424242, "password": "private fixture"]]]
            ]], "diagnosticMetaData": ["launchDuration": "4444 ms", "appBuildVersion": "92"]])
        let safe = DiagnosticPrivacy.runtime(String(decoding: raw, as: UTF8.self))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(safe.utf8)) as? [String: Any])
        let tree = try XCTUnwrap(report["callStackTree"] as? [String: Any])
        let stacks = try XCTUnwrap(tree["callStacks"] as? [[String: Any]])
        XCTAssertEqual(stacks.count, 2, "A large stack must not spend the other stack's entire budget")
        XCTAssertTrue(safe.contains(secondUUID))
        XCTAssertTrue(safe.contains("424242"))
        XCTAssertFalse(safe.contains("private fixture"))
        XCTAssertLessThanOrEqual(safe.utf8.count, 14 * 1024)
        XCTAssertEqual(DiagnosticPrivacy.runtime(safe), safe)
    }

    func testUnattributedThreadsDoNotStealAttributedStackBudget() throws {
        let uuid = "00000000-0000-0000-0000-000000000444"
        var frame: [String: Any] = ["binaryUUID": uuid, "offsetIntoBinaryTextSegment": 321321]
        for index in 0..<30 { frame = ["binaryName": "System", "address": index, "subFrames": [frame]] }
        var stacks: [[String: Any]] = [["threadAttributed": true, "callStackRootFrames": [frame]]]
        stacks += Array(repeating: ["threadAttributed": false, "callStackRootFrames": [["binaryName": "Background"]]], count: 127)
        let raw = try JSONSerialization.data(withJSONObject: ["callStackTree": ["callStacks": stacks]])
        let safe = DiagnosticPrivacy.runtime(String(decoding: raw, as: UTF8.self))
        XCTAssertTrue(safe.contains(uuid), "Unattributed threads must not reduce the useful depth of the attributed thread")
        XCTAssertTrue(safe.contains("321321"))
        XCTAssertEqual(DiagnosticPrivacy.runtime(safe), safe)
    }

    func testDeepFirstBranchCannotExhaustOtherStackNodeBudget() throws {
        let uuid = "00000000-0000-0000-0000-000000000333"
        var frame: [String: Any] = ["binaryName": "System", "sampleCount": 1]
        for index in 0..<60 { frame = ["binaryName": "System", "address": index,
            "sampleCount": 1, "subFrames": [frame]] }
        let raw = try JSONSerialization.data(withJSONObject: ["callStackTree": ["callStacks": [
            ["threadAttributed": true, "callStackRootFrames": Array(repeating: frame, count: 128)],
            ["threadAttributed": true, "callStackRootFrames": [["binaryUUID": uuid,
                "offsetIntoBinaryTextSegment": 999999]]]
        ]]])
        let safe = DiagnosticPrivacy.runtime(String(decoding: raw, as: UTF8.self))
        XCTAssertTrue(safe.contains(uuid), "Cleaning must reserve work as well as output bytes for later stacks")
        XCTAssertTrue(safe.contains("999999"))
        XCTAssertLessThanOrEqual(safe.utf8.count, 14 * 1024)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(safe.utf8)))
        XCTAssertEqual(DiagnosticPrivacy.runtime(safe), safe)
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
