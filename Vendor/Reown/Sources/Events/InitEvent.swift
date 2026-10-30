
import Foundation

struct InitEvent: Codable {
    struct Props: Codable {
        let event: String = "INIT"
        let type: String = "None"
        let properties: Properties

        // Event discriminators are fixed by this event type. Decode the stored
        // payload explicitly while preserving those original constants.
        init(properties: Properties) { self.properties = properties }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            properties = try values.decode(Properties.self, forKey: .properties)
        }
    }

    struct Properties: Codable {
        let clientId: String
        let userAgent: String

        // Custom CodingKeys to map Swift property names to JSON keys
        enum CodingKeys: String, CodingKey {
            case clientId = "client_id"
            case userAgent = "user_agent"
        }
    }

    let eventId: String
    let bundleId: String
    let timestamp: Int64
    let props: Props
}
