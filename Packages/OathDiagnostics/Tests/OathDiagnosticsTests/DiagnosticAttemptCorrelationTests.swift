import Foundation
import XCTest
@testable import OathDiagnostics

final class DiagnosticAttemptCorrelationTests: XCTestCase, @unchecked Sendable {
    func testSyncAttemptCreatesScopeAndRestoresCaller() throws {
        XCTAssertNil(OathDiagnostics.operationID)
        let first = OathDiagnostics.attempt("sync_scope") { OathDiagnostics.operationID }
        let second = OathDiagnostics.attempt("sync_scope") { OathDiagnostics.operationID }
        let one = try XCTUnwrap(try XCTUnwrap(first))
        let two = try XCTUnwrap(try XCTUnwrap(second))
        XCTAssertNotEqual(one, two)
        XCTAssertNil(OathDiagnostics.operationID)
    }

    func testAsyncAttemptCorrelatesProviderAndChildTaskBeforeFailure() async throws {
        let result: Int? = await OathDiagnostics.attempt("native_price") {
            let boundary = try XCTUnwrap(OathDiagnostics.operationID)
            return try await OathDiagnostics.withChain("sui") {
                XCTAssertEqual(OathDiagnostics.operationID, boundary)
                async let child = Task { OathDiagnostics.operationID }.value
                let inherited = await child
                XCTAssertEqual(inherited, boundary)
                throw URLError(.timedOut)
            }
        }
        XCTAssertNil(result)
        XCTAssertNil(OathDiagnostics.operationID)
        XCTAssertNil(OathDiagnostics.chain)
    }

    func testOptionalAttemptPreservesAbsenceAndCancellationSemantics() async throws {
        var identifiers: [UUID] = []
        let absent: Int? = await OathDiagnostics.attemptOptional("optional_quote") {
            identifiers.append(try XCTUnwrap(OathDiagnostics.operationID))
            return nil
        }
        let cancelled: Int? = await OathDiagnostics.attemptOptional("optional_quote") {
            identifiers.append(try XCTUnwrap(OathDiagnostics.operationID))
            throw CancellationError()
        }
        XCTAssertNil(absent); XCTAssertNil(cancelled)
        XCTAssertEqual(Set(identifiers).count, 2)
        XCTAssertNil(OathDiagnostics.operationID)
    }

    func testNestedAttemptsKeepExistingScopeWithoutChangingChain() async throws {
        let identifier = UUID()
        await OathDiagnostics.$operationID.withValue(identifier) {
            await OathDiagnostics.$chain.withValue("near") {
                let result = await OathDiagnostics.attempt("outer") {
                    await OathDiagnostics.attemptOptional("inner") {
                        OathDiagnostics.attempt("sync_inner") {
                            XCTAssertEqual(OathDiagnostics.operationID, identifier)
                            XCTAssertEqual(OathDiagnostics.chain, "near")
                            return 7
                        }
                    }
                }
                XCTAssertEqual(result!, 7)
                XCTAssertEqual(OathDiagnostics.operationID, identifier)
                XCTAssertEqual(OathDiagnostics.chain, "near")
            }
        }
        XCTAssertNil(OathDiagnostics.operationID)
        XCTAssertNil(OathDiagnostics.chain)
    }

    func testConcurrentIndependentAttemptsDoNotShareAnIdentifier() async throws {
        let identifiers = await withTaskGroup(of: UUID?.self, returning: [UUID].self) { group in
            for _ in 0..<4 {
                group.addTask {
                    await OathDiagnostics.attemptOptional("independent_quote") {
                        let identifier = OathDiagnostics.operationID
                        await Task.yield()
                        XCTAssertEqual(OathDiagnostics.operationID, identifier)
                        return identifier
                    }
                }
            }
            var values: [UUID] = []
            for await value in group { if let value { values.append(value) } }
            return values
        }
        XCTAssertEqual(Set(identifiers).count, 4)
        XCTAssertNil(OathDiagnostics.operationID)
    }
}
