import Foundation

protocol LinkEnvelopeRequesting {
    func request(topic: String, request: RPCRequest, peerUniversalLink: String,
                 envelopeType: Envelope.EnvelopeType) async throws -> String
}
