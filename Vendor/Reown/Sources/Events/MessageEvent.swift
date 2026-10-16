
import Foundation

struct MessageEvent: Codable {
    struct Props: Codable {
        let event: String = "SUCCESS"
        let type: String
        let properties: Properties

        // Event discriminators are fixed by this event type. Decode the stored
        // payload explicitly while preserving those original constants.
        init(type: String, properties: Properties) { self.type = type; self.properties = properties }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try values.decode(String.self, forKey: .type)
            properties = try values.decode(Properties.self, forKey: .properties)
        }
    }

    struct Properties: Codable {
        let correlationId: Int64
        let clientId: String
        let direction: Direction

        // Custom CodingKeys to map Swift property names to JSON keys
        enum CodingKeys: String, CodingKey {
            case correlationId = "correlation_id"
            case clientId = "client_id"
            case direction
        }
    }

    enum Direction: String, Codable {
        case sent
        case received
    }

    let eventId: String
    let bundleId: String
    let timestamp: Int64
    let props: Props
}
