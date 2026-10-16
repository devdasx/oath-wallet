import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor XrplPreparationReports: DiagnosticTransport {
    var events = [DiagnosticEvent]()
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

@MainActor final class XrplSendPreparationTests: XCTestCase {
    func testAccountRequirementsKeepQuotesBlockedWithoutHidingRealFailures() async throws {
        let reports = XrplPreparationReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let sender = try XrplSendCrypto.address(privateKey: Data(repeating: 7, count: 32))
        let recipient = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
        let issuer = "r9cZA1mLK5R5Am25ArfXFmqgNwjZgnfk59"
        let transport = XrplRPCFixture(sender: sender, recipient: recipient)
        let client = try XrplSendClient(network: .testnet, transport: transport)
        // Two owned objects: 1 XRP base + 2 * 0.2 XRP + the quoted 12-drop fee.
        // Zero spendable funds and one drop below the fee must stay blocked.
        for balance: UInt64 in [1_400_000, 1_400_011, 1_400_012, 1_400_013] {
            await transport.configure(balance: balance)
            do {
                let plan = try await XrplSendPreparation.run {
                    try await client.quote(sender: sender, recipient: recipient, reference: "native", amount: "1")
                }
                XCTAssertEqual(balance, 1_400_013)
                XCTAssertEqual(plan.amount, "1"); XCTAssertEqual(plan.remaining, "1400000")
                XCTAssertEqual(plan.fee, 12); XCTAssertNoThrow(try plan.validate())
            } catch {
                XCTAssertLessThan(balance, 1_400_013)
                XCTAssertEqual(error as? XrplSendError, balance < 1_400_012 ? .reserve : .insufficientFunds)
            }
        }
        // Insufficient funds is intentionally still reported by this change.
        // Record a baseline so only the three exact account requirements below
        // are excluded, not all errors returned by quote().
        try await Task.sleep(for: .milliseconds(200))
        let initial = await reports.events
        XCTAssertFalse(initial.contains { $0.error.message == "reserve" })
        XCTAssertTrue(initial.contains { $0.error.message == "insufficientFunds" })
        for (reserve, minimum) in [("1", UInt64(1_000_000)), ("2", 2_000_000)] {
            await transport.configure(balance: 10_000_000)
            await transport.activation(reserve)
            do {
                let _ = try await XrplSendPreparation.run {
                    try await client.quote(sender: sender, recipient: recipient, reference: "native", amount: String(minimum - 1))
                }
                XCTFail("Underfunded destination must not become a signable quote")
            } catch {
                XCTAssertEqual(error as? XrplSendError, .recipientMinimum(minimum))
                XCTAssertEqual(SendAccountGuidance.failure(error, native: true)?.action, .editAmount)
            }
            let exact = try await XrplSendPreparation.run {
                try await client.quote(sender: sender, recipient: recipient, reference: "native", amount: String(minimum))
            }
            XCTAssertEqual(exact.amount, String(minimum)); XCTAssertEqual(exact.accountCost?.atomic, String(minimum))
            XCTAssertEqual(exact.assetDebit, exact.amount, "Activation is included in the payment")
        }
        do {
            let _ = try await XrplSendPreparation.run {
                try await client.quote(sender: sender, recipient: recipient, reference: "USD." + issuer,
                    amount: XrplIdentity.issuedAmount("1"))
            }
            XCTFail("Tokens cannot activate the missing destination")
        } catch {
            XCTAssertEqual(error as? XrplSendError, .recipientUnfunded)
            XCTAssertEqual(SendAccountGuidance.failure(error, native: false)?.action, .editRecipient)
        }
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await XrplSendPreparation.run {
                XCTFail("Canceled review must not start work")
            }
        }
        do { try await canceled.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        for succeedsAfterCancel in [false, true] {
            let interrupted = Task {
                try await XrplSendPreparation.run {
                    withUnsafeCurrentTask { $0?.cancel() }
                    if !succeedsAfterCancel { throw XrplSendError.transport }
                    return 7
                }
            }
            do { _ = try await interrupted.value; XCTFail("Canceled review must not publish a quote") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        try await Task.sleep(for: .milliseconds(200))
        let validated = await reports.events
        XCTAssertEqual(validated.count, initial.count, "Account requirements must not create app-error events")
        XCTAssertFalse(validated.contains { $0.error.message == "reserve" || $0.error.message == "recipientUnfunded" || $0.error.message.hasPrefix("recipientMinimum") })

        // An original provider error and its enclosing preparation must retain
        // one operation identity, with no user input or raw response content.
        await transport.fail("noPermission")
        do {
            let _ = try await XrplSendPreparation.run {
                try await client.quote(sender: sender, recipient: recipient, reference: "native", amount: "1")
            }
            XCTFail("Provider rejection cannot become validation or success")
        } catch { XCTAssertEqual(error as? XrplSendError, .rpc("noPermission")) }
        for failure in [XrplSendError.amount, .malformed, .wrongNetwork, .wrongOwner, .simulation("tecFROZEN"), .execution("tecPATH_DRY")] {
            do {
                let _: Int = try await XrplSendPreparation.run { throw failure }
                XCTFail("Unexpected error must propagate")
            } catch { XCTAssertEqual(error as? XrplSendError, failure) }
        }
        do {
            let _: Int = try await XrplSendPreparation.run { throw NSError(domain: "GRDB.DatabaseError", code: 11) }
            XCTFail("Storage error must propagate")
        } catch { XCTAssertEqual((error as NSError).domain, "GRDB.DatabaseError") }
        // No global diagnostic filtering: the same reserve failure after
        // approval must still be observed by the existing submission boundary.
        OathDiagnostics.record(XrplSendError.reserve, component: "xrpl_send", operation: "submit", context: ["chain": "xrpl"])
        for _ in 0..<100 {
            if await reports.events.contains(where: { $0.operation == "submit" }),
               await reports.events.contains(where: { $0.error.domain == "GRDB.DatabaseError" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events
        let rpcMessage = DiagnosticPrivacy.text(String(describing: XrplSendError.rpc("noPermission")))
        let enclosing = try XCTUnwrap(events.first { $0.operation == "prepare" && $0.context["stage"] == "quote" && $0.error.message == rpcMessage })
        let provider = try XCTUnwrap(events.first { $0.error.domain == "XrplRPC" })
        XCTAssertNotNil(enclosing.operationID); XCTAssertEqual(provider.operationID, enclosing.operationID)
        XCTAssertEqual(provider.context["chain"], "xrpl")
        XCTAssertTrue(events.contains { $0.operation == "submit" && $0.error.message == "reserve" })
        for failure in [XrplSendError.amount, .malformed, .wrongNetwork, .wrongOwner, .simulation("tecFROZEN"), .execution("tecPATH_DRY")] {
            let expected = DiagnosticPrivacy.text(String(describing: failure))
            XCTAssertTrue(events.contains { $0.error.message == expected }, "Real failure still needs reporting: " + expected)
        }
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for value in [sender, recipient, issuer, "PRIVATE_RESPONSE_MARKER", "\"params\"", "\"body\"", "\"request\""] {
            XCTAssertFalse(encoded.contains(value))
        }
        let writes = await transport.submitted
        XCTAssertTrue(writes.isEmpty)
    }
}
