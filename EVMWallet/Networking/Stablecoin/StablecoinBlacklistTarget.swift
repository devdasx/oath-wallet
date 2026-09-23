import Foundation

struct StablecoinBlacklistTarget: Equatable, Sendable, Identifiable {
    enum Method: String, Codable, Sendable {
        case tether, circle, blocked
        var selector: String {
            switch self { case .tether: "e47d6060"; case .circle: "fe575a87"; case .blocked: "fbac3951" }
        }
        var signature: String {
            switch self {
            case .tether: "isBlackListed(address)"
            case .circle: "isBlacklisted(address)"
            case .blocked: "isBlocked(address)"
            }
        }
    }

    let networkID: String
    let chainID: UInt64
    let symbol: String
    let contract: String
    let method: Method?
    let endpoint: String
    var fallbackEndpoints: [String] = []
    var id: String { networkID + ":" + contract.lowercased() }
}
