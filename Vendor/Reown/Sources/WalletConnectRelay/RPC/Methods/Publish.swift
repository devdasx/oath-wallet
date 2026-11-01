
import Foundation

public struct Publish: RelayRPC {

    struct Params: Codable {
        let topic: String
        let message: String
        let ttl: Int
        let prompt: Bool?
        let tag: Int?

        let correlationId: RPCID?
        let rpcMethods: [String]?
        let chainId: Blockchain?
        let txHashes: [String]?
        let contractAddresses: [String]?

        init(topic: String, message: String, ttl: Int, prompt: Bool?, tag: Int?, correlationId: RPCID?, tvfData: TVFData?) {
            self.topic = topic
            self.message = message
            self.ttl = ttl
            self.prompt = prompt
            self.tag = tag
            self.correlationId = correlationId
            self.rpcMethods = tvfData?.rpcMethods
            self.chainId = tvfData?.chainId
            self.txHashes = tvfData?.txHashes
            self.contractAddresses = tvfData?.contractAddresses
        }

        // Publish only relay routing fields and the encrypted peer message.
        // Optional transaction analytics must not bypass Oath's telemetry policy,
        // including when parameters were decoded rather than created above.
        private enum RoutingKeys: String, CodingKey {
            case topic, message, ttl, prompt, tag, correlationId
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: RoutingKeys.self)
            try container.encode(topic, forKey: .topic)
            try container.encode(message, forKey: .message)
            try container.encode(ttl, forKey: .ttl)
            try container.encodeIfPresent(prompt, forKey: .prompt)
            try container.encodeIfPresent(tag, forKey: .tag)
            try container.encodeIfPresent(correlationId, forKey: .correlationId)
        }
    }

    let params: Params

    var method: String {
        "irn_publish"
    }
}
