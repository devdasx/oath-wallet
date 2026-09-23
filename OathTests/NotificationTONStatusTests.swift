import Foundation
import Testing
@testable import Aperture

struct NotificationTONStatusTests {
    private static let account = "0:" + String(repeating: "a", count: 64)
    private static let recipient = "0:" + String(repeating: "b", count: 64)
    private static let hash = String(repeating: "c", count: 64)

    private func event(status: String, pending: Bool = false) throws -> TONAPIEvents.Event {
        let json = """
        {"event_id":"\(Self.hash)","timestamp":1,"in_progress":\(pending),"actions":[
          {"type":"TonTransfer","status":"\(status)","TonTransfer":{
            "sender":{"address":"\(Self.account)"},"recipient":{"address":"\(Self.recipient)"},"amount":"1000000000"}}
        ]}
        """
        return try JSONDecoder().decode(TONAPIEvents.Event.self, from: Data(json.utf8))
    }

    @Test(arguments: [("ok", false, SendTransactionNetworkStatus.confirmed),
                       ("failed", false, .failed), ("ok", true, .pending)])
    func distinguishesActualEventStates(status: String, pending: Bool, expected: SendTransactionNetworkStatus) throws {
        #expect(try NotificationTONStatusProvider.status(event: event(status: status, pending: pending),
            account: Self.account, contractAddress: nil) == expected)
    }

    @Test func rejectsUnknownStatusAndUnrelatedTransfers() throws {
        #expect(throws: (any Error).self) {
            try NotificationTONStatusProvider.status(event: event(status: "unknown"), account: Self.account, contractAddress: nil)
        }
        #expect(throws: (any Error).self) {
            try NotificationTONStatusProvider.status(event: event(status: "ok"), account: "0:" + Self.hash, contractAddress: nil)
        }
        #expect(throws: (any Error).self) {
            try NotificationTONStatusProvider.status(event: event(status: "ok"), account: Self.account, contractAddress: Self.recipient)
        }
    }

    @Test(arguments: [404, 401, 429, 500])
    func missingEventIsNotFoundButProviderFailuresRemainErrors(code: Int) async throws {
        let provider = NotificationTONStatusProvider { request in
            #expect(request.url?.path == "/v2/events/\(Self.hash)")
            #expect(request.httpMethod == "GET")
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
        if code == 404 {
            #expect(try await provider.status(hash: Self.hash, accountAddress: Self.account, contractAddress: nil) == .notFound)
        } else {
            await #expect(throws: (any Error).self) {
                try await provider.status(hash: Self.hash, accountAddress: Self.account, contractAddress: nil)
            }
        }
    }

    @Test func jettonStatusRequiresTheActualContractAndParties() throws {
        let json = """
        {"event_id":"\(Self.hash)","timestamp":1,"in_progress":false,"actions":[
          {"type":"JettonTransfer","status":"ok","JettonTransfer":{
            "sender":{"address":"\(Self.account)"},"recipient":{"address":"\(Self.recipient)"},"amount":"123456789123456789",
            "jetton":{"address":"\(Self.recipient)","name":"Token","symbol":"TOKEN","decimals":6}}}
        ]}
        """
        let event = try JSONDecoder().decode(TONAPIEvents.Event.self, from: Data(json.utf8))
        #expect(try NotificationTONStatusProvider.status(event: event, account: Self.account,
            contractAddress: Self.recipient, sender: Self.account, recipient: Self.recipient) == .confirmed)
        #expect(throws: (any Error).self) {
            try NotificationTONStatusProvider.status(event: event, account: Self.account, contractAddress: Self.account)
        }
        #expect(throws: (any Error).self) {
            try NotificationTONStatusProvider.status(event: event, account: Self.account,
                contractAddress: Self.recipient, sender: Self.recipient)
        }
    }

    #if LIVE_MAINNET_TESTS
    @Test func realMainnetJettonTransferResolvesByContract() async throws {
        #expect(try await NotificationTONStatusProvider().status(
            hash: "99ef1ccd27271ea0885d316078cc5be05f32c0613e60221174477af8064ea401",
            accountAddress: "0:23fa979918f1fe702db9100bf843e87c7015eccd39a4721e9b6bac170bc04ce3",
            contractAddress: "0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe"
        ) == .confirmed)
    }

    @Test func realMainnetEventAndTransactionAliasesResolve() async throws {
        let provider = NotificationTONStatusProvider()
        for hash in ["cdc66226bd0ce4a0e2fa96923eb66f28e6311a3b0ee68ae2f52f7a87d7447282",
                     "ed36157ff40d92204a7770a875f032d2b24b71bffb58c886e930e3e2383cb2ce"] {
            #expect(try await provider.status(hash: hash,
                accountAddress: "0:b2c7fd01ce33fdc1f19fc3bd86d6fb6ae5844c6f3471fe616932aa3e753cec68",
                contractAddress: nil) == .confirmed)
        }
    }
    #endif
}
