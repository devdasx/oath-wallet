import XCTest
import CryptoKit
@testable import OathAnkr

/// Disposable fixtures only. Exercises the production transaction parser and
/// RPC review with binary SPL account layouts; no network or funded accounts.
final class WalletConnectSolanaPermissionTests: XCTestCase {
    private let source = key(2), mint = key(3), delegate = key(4), table = key(5)
    private var owner: String { get throws { SolanaSendCrypto.encode(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)).publicKey.rawRepresentation) } }

    private func request(program: String = SolanaIdentity.tokenProgram, checked: Bool = false, amount: UInt64 = .max,
                         opcode: UInt8? = nil, lookupCount: Int = 0, method: String = "solana_signTransaction",
                         revokeAfter: Bool = false) throws -> WalletConnectSolanaRequest {
        let versioned = lookupCount > 0
        let keys = versioned ? [try owner, mint, delegate, program] : [try owner, source, mint, delegate, program]
        var message = Data(versioned ? [128,1,0,3] : [1,0,3])
        message.append(UInt8(keys.count))
        for key in keys { message += try SolanaSendCrypto.decode(key) }
        message += Data(repeating: 7, count: 32)
        message.append(revokeAfter ? 2 : 1)
        let code = opcode ?? (checked ? 13 : 4)
        let indices: [UInt8] = versioned ? (checked ? [4,1,2,0] : [4,2,0]) : (checked ? [1,2,3,0] : [1,3,0])
        let data = code == 5 ? Data([code]) : Data([code]) + le(amount) + (checked ? Data([6]) : Data())
        message.append(UInt8(keys.count-1)); message.append(UInt8(indices.count)); message += Data(indices)
        message.append(UInt8(data.count)); message += data
        if revokeAfter { message += Data([UInt8(keys.count-1), 2, versioned ? 4 : 1, 0, 1, 5]) }
        if versioned {
            message.append(1); message += try SolanaSendCrypto.decode(table)
            message.append(UInt8(lookupCount)); message += Data((0..<lookupCount).map(UInt8.init)); message.append(0)
        }
        let wire = Data([1]) + Data(repeating: 0, count: 64) + message
        let params: SolanaJSON = method == "solana_signAllTransactions" ? .object(["transactions": .array([.string(wire.base64EncodedString())])]) : .object(["transaction": .string(wire.base64EncodedString())])
        return try .init(method: method, chain: SolanaSendNetwork.devnet.walletConnectChain, account: owner, params: JSONEncoder().encode(params))
    }

    private func token(program: String = SolanaIdentity.tokenProgram, delegate: String? = nil, allowance: UInt64 = 0,
                       amount: UInt64 = 1_000_000_000, owner override: String? = nil, extensionType: UInt8? = nil,
                       edit: (inout Data) -> Void = { _ in }) throws -> SolanaJSON {
        var bytes = Data(repeating: 0, count: 165)
        bytes.replaceSubrange(0..<32, with: try SolanaSendCrypto.decode(mint))
        bytes.replaceSubrange(32..<64, with: try SolanaSendCrypto.decode(override ?? owner))
        bytes.replaceSubrange(64..<72, with: le(amount)); bytes[108] = 1
        if let delegate { bytes[72] = 1; bytes.replaceSubrange(76..<108, with: try SolanaSendCrypto.decode(delegate)) }
        bytes.replaceSubrange(121..<129, with: le(allowance))
        if let extensionType { bytes += Data([extensionType, 7,0,0,0]) }
        edit(&bytes)
        return account(bytes, program: program)
    }

    private func transport(_ request: WalletConnectSolanaRequest, before: SolanaJSON, after: SolanaJSON,
                           mintValue: SolanaJSON? = nil, extra: [String: (SolanaJSON, SolanaJSON)] = [:]) throws -> PermissionTransport {
        var mintBytes = Data(repeating: 0, count: 82); mintBytes[44] = 6; mintBytes[45] = 1
        var tableBytes = Data([1,0,0,0]) + Data(repeating: 0, count: 52)
        for i in 0..<(request.transactions[0].lookups.first?.writable.count ?? 0) {
            tableBytes += try SolanaSendCrypto.decode(i == 0 ? source : key(UInt8(20+i)))
        }
        var pre: [String: SolanaJSON] = [try owner: .object(["lamports": .number("100000")]), source: before]
        var post: [String: SolanaJSON] = [try owner: .object(["lamports": .number("95000")]), source: after]
        for (address, pair) in extra { pre[address] = pair.0; post[address] = pair.1 }
        return PermissionTransport(before: pre, after: post, infos: [mint: mintValue ?? account(mintBytes, program: SolanaIdentity.tokenProgram), table: account(tableBytes, program: "AddressLookupTab1e1111111111111111111111111")])
    }

    private func review(_ request: WalletConnectSolanaRequest, before: SolanaJSON, after: SolanaJSON,
                        mintValue: SolanaJSON? = nil) async throws -> WalletConnectSolanaReview {
        try await SolanaSendClient(network: .devnet, transport: transport(request, before: before, after: after, mintValue: mintValue)).walletConnectReview(request)[0]
    }

    func testApproveAndApproveCheckedExposeExactSpenderAndUnlimitedAccessAcrossBothProgramsAndMethods() async throws {
        for program in [SolanaIdentity.tokenProgram, SolanaIdentity.token2022Program] {
            for checked in [false, true] {
                for method in ["solana_signTransaction", "solana_signAndSendTransaction", "solana_signAllTransactions"] {
                    let input = try request(program: program, checked: checked, method: method)
                    let result = try await review(input, before: token(program: program), after: token(program: program, delegate: delegate, allowance: .max))
                    XCTAssertEqual(result.changes.map(\.reference), ["native"])
                    XCTAssertEqual(result.delegations.count, 1)
                    let change = try XCTUnwrap(result.delegations.first)
                    XCTAssertEqual(change.tokenAccount, source); XCTAssertEqual(change.mint, mint)
                    XCTAssertEqual(change.program, program); XCTAssertEqual(change.decimals, 6)
                    XCTAssertNil(change.before); XCTAssertEqual(change.after?.delegate, delegate)
                    XCTAssertEqual(change.after?.amount, UInt64.max); XCTAssertEqual(change.after?.unlimited, true)
                    XCTAssertEqual(change.requested, [change.after!]); XCTAssertFalse(result.incomplete)
                }
            }
        }
    }

    func testFiniteZeroAndRepeatedApprovalRemainVisibleWithoutBalanceChanges() async throws {
        for amount: UInt64 in [0, 1, 5_000_000, UInt64.max-1, UInt64.max] {
            let input = try request(amount: amount), state = try token(delegate: delegate, allowance: amount)
            let result = try await review(input, before: state, after: state)
            let permission = try XCTUnwrap(result.delegations.first)
            XCTAssertEqual(permission.before, permission.after)
            XCTAssertEqual(permission.requested.first?.amount, amount)
            XCTAssertEqual(permission.requested.first?.unlimited, amount == UInt64.max)
        }
    }

    func testCPIAndVersionedLookupDelegationsCannotHideBehindUnchangedBalances() async throws {
        for count in [0, 1, 63] {
            let input = try request(program: key(9), lookupCount: count)
            let result = try await review(input, before: token(), after: token(delegate: delegate, allowance: .max))
            XCTAssertEqual(result.delegations.first?.after?.delegate, delegate)
            XCTAssertEqual(result.delegations.first?.requested, [])
            XCTAssertEqual(result.inspectedAccounts, count == 0 ? 2 : count+1)
            XCTAssertFalse(result.incomplete)
        }
    }

    func testAccountBeyondSimulationLimitFailsInsteadOfBeingOmitted() async throws {
        let input = try request(program: key(9), lookupCount: 64)
        let transport = try transport(input, before: token(), after: token(delegate: delegate, allowance: .max))
        do { _ = try await SolanaSendClient(network: .devnet, transport: transport).walletConnectReview(input); XCTFail("Omitted writable account") }
        catch { XCTAssertEqual(error as? SolanaSendError, .unsupportedToken) }
        let calls = await transport.methods
        XCTAssertFalse(calls.contains("simulateTransaction"))
    }

    func testReplacementRevocationAndTransientApprovalPreserveBothStates() async throws {
        let previous = try token(delegate: key(8), allowance: 100)
        let replacement = try await review(request(amount: 50), before: previous, after: token(delegate: delegate, allowance: 50))
        XCTAssertEqual(replacement.delegations.first?.before?.delegate, key(8))
        XCTAssertEqual(replacement.delegations.first?.before?.amount, 100)
        XCTAssertEqual(replacement.delegations.first?.after?.amount, 50)
        let revoked = try await review(request(opcode: 5), before: previous, after: token())
        XCTAssertNil(revoked.delegations.first?.after); XCTAssertEqual(revoked.delegations.count, 1)
        let transient = try await review(request(revokeAfter: true), before: token(), after: token())
        XCTAssertNil(transient.delegations.first?.after)
        XCTAssertEqual(transient.delegations.first?.requested.first?.amount, UInt64.max)
    }

    func testDirectLookupApprovalAndSigningPreserveExactMessage() async throws {
        let input = try request(checked: true, lookupCount: 1)
        let result = try await review(input, before: token(), after: token(delegate: delegate, allowance: .max))
        XCTAssertEqual(result.delegations.first?.tokenAccount, source)
        XCTAssertEqual(result.delegations.first?.requested.first?.delegate, delegate)
        let signed = try input.sign(privateKey: Data(repeating: 1, count: 32))
        try input.transactions[0].verifySigned(signed.transactions[0], requireAll: true)
        let parsed = try WalletConnectSolanaTransaction(bytes: signed.transactions[0], account: owner)
        XCTAssertEqual(parsed.message, input.transactions[0].message)
        XCTAssertEqual(parsed.instructions, input.transactions[0].instructions)
    }

    func testOrdinaryTransferStillShowsMinus1000WithoutNewPermission() async throws {
        let result = try await review(request(opcode: 3), before: token(), after: token(amount: 0))
        XCTAssertTrue(result.delegations.isEmpty)
        let transfer = try XCTUnwrap(result.changes.first { $0.reference == mint })
        XCTAssertEqual(transfer.amount, 1_000_000_000); XCTAssertEqual(transfer.decimals, 6); XCTAssertFalse(transfer.increase)
    }

    func testToken2022ExtendedAccountsAndUnknownMintPrecision() async throws {
        let input = try request(program: SolanaIdentity.token2022Program)
        let result = try await review(input, before: token(program: SolanaIdentity.token2022Program, extensionType: 2),
            after: token(program: SolanaIdentity.token2022Program, delegate: delegate, allowance: 123456789, extensionType: 2), mintValue: .null)
        XCTAssertEqual(result.delegations.first?.after?.amount, 123456789)
        XCTAssertNil(result.delegations.first?.decimals)
    }

    func testPermissionOnlyChangesInvalidateConsentButNewSlotDoesNot() async throws {
        let input = try request(program: key(9))
        let original = try await review(input, before: token(), after: token(delegate: delegate, allowance: 100))
        for post in [try token(delegate: key(8), allowance: 100), try token(delegate: delegate, allowance: 101), try token()] {
            let changed = try await review(input, before: token(), after: post)
            XCTAssertEqual(original.changes, changed.changes); XCTAssertEqual(original.fee, changed.fee)
            XCTAssertEqual(original.programs, changed.programs); XCTAssertFalse(original.matchesConsent(changed))
        }
        let newSlot = WalletConnectSolanaReview(fee: original.fee, programs: original.programs, changes: original.changes,
            slot: original.slot+1, delegations: original.delegations, inspectedAccounts: original.inspectedAccounts, totalWritableAccounts: original.totalWritableAccounts)
        XCTAssertTrue(original.matchesConsent(newSlot))
    }

    func testMalformedPermissionStateAndUnsupportedAuthorityChangesFailClosed() async throws {
        let input = try request()
        let malformed: [SolanaJSON] = [
            try token(delegate: delegate, allowance: .max, edit: { $0[72] = 2 }),
            try token(edit: { $0[129] = 2 }), try token(edit: { $0[108] = 3 }),
            try token(edit: { $0[109] = 2 }), try token(edit: { $0.removeLast() }),
            try token(program: SolanaIdentity.token2022Program, extensionType: 3)
        ]
        for post in malformed {
            do { _ = try await review(input, before: token(), after: post); XCTFail("Malformed state accepted") }
            catch { XCTAssertEqual(error as? SolanaSendError, .malformed) }
        }
        for post in [try token(owner: key(8)), try token(edit: { $0[129] = 1; $0.replaceSubrange(133..<165, with: Data(repeating: 8, count: 32)) })] {
            do { _ = try await review(input, before: token(), after: post); XCTFail("Authority change hidden") }
            catch { XCTAssertEqual(error as? SolanaSendError, .unsupportedToken) }
        }
    }

    func testMultipleAccountsOfSameMintKeepIndependentDelegates() async throws {
        let input = try request(program: key(9), lookupCount: 2)
        let transport = try transport(input, before: token(), after: token(delegate: delegate, allowance: 100),
            extra: [key(21): (try token(), try token(delegate: key(8), allowance: 200))])
        let result = try await SolanaSendClient(network: .devnet, transport: transport).walletConnectReview(input)[0]
        XCTAssertEqual(result.delegations.count, 2)
        XCTAssertEqual(Set(result.delegations.map(\.mint)), [mint])
        XCTAssertEqual(Set(result.delegations.compactMap { $0.after?.delegate }), [delegate, key(8)])
    }

    func testMintAndMultisigDataAreNotInterpretedAsDelegation() throws {
        for size in [82, 355] {
            XCTAssertNil(try SolanaSendClient.walletConnectTokenState(account(Data(repeating: 0, count: size), program: SolanaIdentity.tokenProgram)))
        }
        let extendedMint = Data(repeating: 0, count: 165) + Data([1, 0, 0, 0, 0])
        XCTAssertNil(try SolanaSendClient.walletConnectTokenState(account(extendedMint, program: SolanaIdentity.token2022Program)))
    }
}

private func key(_ byte: UInt8) -> String { SolanaSendCrypto.encode(Data(repeating: byte, count: 32)) }
private func le(_ amount: UInt64) -> Data { Data((0..<8).map { UInt8(truncatingIfNeeded: amount >> ($0*8)) }) }
private func account(_ bytes: Data, program: String) -> SolanaJSON {
    .object(["owner": .string(program), "data": .array([.string(bytes.base64EncodedString()), .string("base64")])])
}

private actor PermissionTransport: AnkrTransport {
    let before: [String: SolanaJSON], after: [String: SolanaJSON], infos: [String: SolanaJSON]
    var methods: [String] = []
    init(before: [String: SolanaJSON], after: [String: SolanaJSON], infos: [String: SolanaJSON]) { self.before = before; self.after = after; self.infos = infos }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        XCTAssertEqual(request.url?.host, "api.devnet.solana.com")
        let json = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        let method = try XCTUnwrap(json["method"].string), params = json["params"].array ?? []
        methods.append(method)
        let result: SolanaJSON
        switch method {
        case "getGenesisHash": result = .string(SolanaSendNetwork.devnet.genesis)
        case "isBlockhashValid": result = .object(["value": .bool(true)])
        case "getAccountInfo": result = .object(["value": infos[params[0].string ?? ""] ?? .null])
        case "getMultipleAccounts":
            result = .object(["context": .object(["slot": .number("123")]), "value": .array((params[0].array ?? []).map { before[$0.string ?? ""] ?? .null })])
        case "simulateTransaction":
            result = .object(["value": .object(["err": .null, "accounts": .array((params[1]["accounts"]["addresses"].array ?? []).map { after[$0.string ?? ""] ?? .null })])])
        case "getFeeForMessage": result = .object(["value": .number("5000")])
        default: XCTFail("Unexpected method \(method)"); throw SolanaSendError.malformed
        }
        return (try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": json["id"], "result": result])), 200)
    }
}
