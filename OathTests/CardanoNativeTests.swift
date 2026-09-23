import Foundation
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized) struct CardanoNativeTests {
    // Public upstream test vector, not a user credential.
    private let key = Data(hexString: "089b68e458861be0c44bf9f7967f05cc91e51ede86dc679448a3566990b7785bd48c330875b1e0d03caaed0e67cecc42075dce1c7a13b1c49240508848ac82f603391c68824881ae3fc23a56a1a75ada3b96382db502e37564e84a5413cfaf1290dbd508e5ec71afaea98da2df1533c22ef02a26bb87b31907d0b2738fb7785b38d53aa68fc01230784c9209b2b2a2faf28491b3b1f1d221e63e704bbd0403c4154425dfbb01a2c5c042da411703603f89af89e57faae2946e2a5c18b1c5ca0e")!
    private let sender = "addr1q8043m5heeaydnvtmmkyuhe6qv5havvhsf0d26q3jygsspxlyfpyk6yqkw0yhtyvtr0flekj84u64az82cufmqn65zdsylzk23"
    private let recipient = "addr1q92cmkgzv9h4e5q7mnrzsuxtgayvg4qr7y3gyx97ukmz3dfx7r9fu73vqn25377ke6r0xk97zw07dqr9y5myxlgadl2s0dgke5"
    private var parameters: CardanoProtocolParameters {
        .init(feePerByte: 44, feeConstant: 155381, coinsPerUTXOByte: 4310,
              maxTransactionSize: 16384, slot: 53331533)
    }
    private var utxos: [CardanoUTXO] { [
        .init(hash: "f074134aabbfb13b8aec7cf5465b1e5a862bde5cb88532cc7e64619179b3e767", index: 1, amount: 1500000, tokenCount: 0),
        .init(hash: "554f2fd942a23d06835d26bbd78f0106fa94c8a551114a0bef81927f66467af0", index: 0, amount: 6500000, tokenCount: 0)
    ] }
    private func snapshot(_ outputs: [CardanoUTXO]? = nil) -> CardanoSnapshot {
        .init(address: sender, balance: 8000000, utxos: outputs ?? utxos, history: [])
    }

    @Test func mainnetValidationRejectsRewardTestnetAndMalformedAddresses() {
        #expect(CardanoAddress.validated(sender) == sender)
        #expect(!CardanoAddress.isKeyPaymentAddress("addr1w8z0xlftcx54tn7uxdvhk0qgj9u7hmlaccjthnc9kvu4pmcyemglm"))
        #expect(CardanoAddress.validated("stake1u8ulx2dmkzx8254lcnav3fycjmt9a49kxes789gdxk5j2tgdjstkl") == nil)
        #expect(CardanoAddress.validated(sender.replacingOccurrences(of: "addr1", with: "addr_test1")) == nil)
        #expect(CardanoAddress.validated(String(sender.dropLast()) + "x") == nil)
    }

    @Test func cip1852DerivesDoubleExtendedKey() throws {
        let wallet = try #require(HDWallet(mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", passphrase: ""))
        let material = try CardanoAddress.material(wallet: wallet)
        #expect(material.address == wallet.getAddressForCoin(coin: .cardano))
        #expect(material.derivationPath == "m/1852'/1815'/0'/0/0")
        #expect(material.publicKey.count == 256)
    }

    @Test func nativeSendConservesFundsAndCoversCurrentSerializedFee() throws {
        let tx = try CardanoNativeTransaction.sign(snapshot: snapshot(), recipient: recipient,
            amount: 6000000, sendMax: false, privateKey: key, parameters: parameters)
        #expect(tx.inputs.reduce(0) { $0 + $1.amount } == tx.amount + tx.change + tx.fee)
        #expect(tx.amount == 6000000)
        #expect(tx.fee >= 155381 + 44 * UInt64(tx.encoded.count))
        #expect(tx.change >= (try CardanoNativeTransaction.minimumOutput(sender, parameters: parameters)))
        #expect(tx.encoded.first == 0x84)
        #expect(tx.encoded.suffix(2) == Data([0xf5, 0xf6]))
        #expect(tx.hash.count == 64)
    }

    @Test func maxNeverSpendsTokenBearingOutputs() throws {
        let token = CardanoUTXO(hash: String(repeating: "a", count: 64), index: 0, amount: 9000000, tokenCount: 1)
        let tx = try CardanoNativeTransaction.sign(snapshot: snapshot(utxos + [token]), recipient: recipient,
            amount: 0, sendMax: true, privateKey: key, parameters: parameters)
        #expect(tx.inputs.count == 2)
        #expect(tx.amount + tx.fee == 8000000)
        #expect(tx.change == 0)
        #expect(!tx.inputs.contains(token))
    }

    @Test func rejectsTokenOnlyFundsWrongKeyDustAndDuplicateInputs() {
        let token = CardanoUTXO(hash: String(repeating: "a", count: 64), index: 0, amount: 9000000, tokenCount: 1)
        #expect(throws: (any Error).self) { try CardanoNativeTransaction.sign(snapshot: snapshot([token]), recipient: recipient, amount: 1000000, sendMax: false, privateKey: key, parameters: parameters) }
        #expect(throws: (any Error).self) { try CardanoNativeTransaction.sign(snapshot: snapshot(), recipient: recipient, amount: 1000000, sendMax: false, privateKey: Data(repeating: 0, count: 32), parameters: parameters) }
        #expect(throws: (any Error).self) { try CardanoNativeTransaction.sign(snapshot: snapshot(), recipient: recipient, amount: 1, sendMax: false, privateKey: key, parameters: parameters) }
        #expect(throws: (any Error).self) { try CardanoNativeTransaction.sign(snapshot: snapshot(utxos + utxos), recipient: recipient, amount: 1000000, sendMax: false, privateKey: key, parameters: parameters) }
    }

    @Test func upstreamSigningVectorAndEnvelopePreserveBody() throws {
        // Trust Wallet Core 4.7.3, Cardano/SigningTests.cpp, SignTransfer1.
        var input = CardanoSigningInput()
        input.privateKey = [key]
        input.ttl = 53333333
        input.transferMessage.toAddress = recipient
        input.transferMessage.changeAddress = sender
        input.transferMessage.amount = 7000000
        input.utxos = utxos.map { output in
            var value = CardanoTxInput()
            value.outPoint.txHash = Data(hexString: output.hash)!
            value.outPoint.outputIndex = output.index
            value.address = sender
            value.amount = output.amount
            return value
        }
        let signed: CardanoSigningOutput = AnySigner.sign(input: input, coin: .cardano)
        #expect(signed.error == .ok)
        #expect(signed.txID.hexString == "9b5b15e133cd73ccaa85307d2986aebc846505118a2eb4e6111e6b4b67d1f389")
        let modern = try CardanoNativeTransaction.currentEraEnvelope(signed.encoded)
        #expect(modern.dropFirst().dropLast(2) == signed.encoded.dropFirst().dropLast())
    }

    @Test func liveWireShapeParsesExactBalanceAndHistory() async throws {
        let address = sender
        let hash = String(repeating: "a", count: 64)
        CardanoFixtureProtocol.handler = { request in
            let history = request.url!.query!.contains("history")
            let row: [String: Any] = history
                ? ["tx_hash": hash, "amount": "1234567", "tx_fee": "170000", "block_no": 13960876, "time": 1789819218]
                : ["tx_hash": hash, "tx_index": 0, "amount": "1234567", "token": 0, "tokens": ["rows": []]]
            let body: [String: Any] = ["code": 200, "data": ["address": address, "balance": "1234567"], "rows": [row], "cursor": ["next": false]]
            return (200, try JSONSerialization.data(withJSONObject: body))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CardanoFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let snapshot = try await CardanoAPIClient(session: session).snapshot(address: sender)
        #expect(snapshot.balance == 1234567)
        #expect(snapshot.history.first?.delta == 1234567)
        #expect(snapshot.history.first?.block == 13960876)
        #expect(snapshot.utxos.first?.index == 0)
        CardanoFixtureProtocol.handler = { _ in
            let body: [String: Any] = ["code": 200, "data": ["address": address + "x", "balance": "0"], "rows": [], "cursor": ["next": false]]
            return (200, try JSONSerialization.data(withJSONObject: body))
        }
        await #expect(throws: (any Error).self) { try await CardanoAPIClient(session: session).snapshot(address: address, includeHistory: false) }
        CardanoFixtureProtocol.handler = { _ in (429, Data()) }
        await #expect(throws: (any Error).self) { try await CardanoAPIClient(session: session).snapshot(address: address, includeHistory: false) }
    }

    @Test func submitUsesCBORAndChecksReturnedTransactionID() async throws {
        let hash = String(repeating: "a", count: 64)
        let bytes = Data([0x84, 0xa0, 0xa0, 0xf5, 0xf6])
        CardanoFixtureProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/cbor")
            #expect(request.url?.path == "/api/v1/submittx")
            return (200, Data(("\"" + hash + "\"").utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CardanoFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = CardanoAPIClient(session: session)
        try await api.submit(bytes, expectedHash: hash)
        await #expect(throws: (any Error).self) { try await api.submit(bytes, expectedHash: String(repeating: "b", count: 64)) }
    }

    @Test func stableSnapshotRequired() throws {
        let row: [String: Any] = ["tx_hash": String(repeating: "a", count: 64), "tx_index": UInt64(0), "amount": "1234567", "token": 0, "tokens": ["rows": []]]
        let page: [String: Any] = ["data": ["balance": "1234567"], "rows": [row], "cursor": ["next": false]]
        let result = try CardanoAPIClient.reconcile([page])
        #expect(result.0 == 1234567)
        #expect(result.1.count == 1)
        #expect(throws: (any Error).self) { try CardanoAPIClient.reconcile([page, page]) }
        var partial = page
        partial["cursor"] = ["next": true]
        #expect(throws: (any Error).self) { try CardanoAPIClient.reconcile([partial]) }
        var changed = page
        changed["data"] = ["balance": "0"]
        #expect(throws: (any Error).self) { try CardanoAPIClient.reconcile([changed]) }
    }
}

private final class CardanoFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
