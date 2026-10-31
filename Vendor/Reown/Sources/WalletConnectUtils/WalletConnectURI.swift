import Foundation

public struct WalletConnectURI: Equatable {
    public enum Errors: Error {
          case expired
          case invalidFormat
      }
    public let topic: String
    public let version: String
    public let symKey: String
    public let relay: RelayProtocolOptions
    public let methods: [String]?
    public let expiryTimestamp: UInt64

    public var absoluteString: String {
        return "wc:\(topic)@\(version)?\(queryString)"
    }


    public var deeplinkUri: String {
        return absoluteString
            .addingPercentEncoding(withAllowedCharacters: .rfc3986) ?? absoluteString
    }

    public init(topic: String, symKey: String, relay: RelayProtocolOptions, methods: [String]? = nil) {
        self.version = "2"
        self.topic = topic
        self.symKey = symKey
        self.relay = relay
        self.methods = methods
        self.expiryTimestamp = fiveMinutesFromNow
    }

    @available(*, deprecated, message: "Use the throwing initializer instead")
    public init?(string: String) {
        do {
            try self.init(uriString: string)
        } catch {
            print("Initialization failed: \(error.localizedDescription)")
            return nil
        }
    }

    public init(uriString: String) throws {
        guard let components = Self.parseURIComponents(from: uriString) else {
            throw Errors.invalidFormat
        }
        // Decode query values only through URLComponents. Decoding the whole
        // URI first lets an encoded ampersand introduce another protocol field.
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard query[item.name] == nil, let value = item.value else {
                throw Errors.invalidFormat
            }
            query[item.name] = value
        }

        guard
            let topic = components.user,
            let version = components.host,
            let symKey = query["symKey"],
            let relayProtocol = query["relay-protocol"]
        else {
            throw Errors.invalidFormat
        }

        let relayData = query["relay-data"]
        let methodsString = query["methods"]
        let methods = methodsString?.components(separatedBy: ",")

        // Check if expiryTimestamp is provided and valid
        if let expiryTimestampString = query["expiryTimestamp"],
           let expiryTimestamp = UInt64(expiryTimestampString),
           expiryTimestamp <= UInt64(Date().timeIntervalSince1970) {
            throw Errors.expired
        }

        self.version = version
        self.topic = topic
        self.symKey = symKey
        self.relay = RelayProtocolOptions(protocol: relayProtocol, data: relayData)
        self.methods = methods
        self.expiryTimestamp = UInt64(query["expiryTimestamp"] ?? "") ?? fiveMinutesFromNow
    }


    public init(deeplinkUri: URL) throws {
        let uriString = deeplinkUri.query?.replacingOccurrences(of: "uri=", with: "") ?? ""
        try self.init(uriString: uriString)
    }

    private var queryString: String {
        var parts = [URLQueryItem(name: "symKey", value: symKey),
                     URLQueryItem(name: "relay-protocol", value: relay.protocol),
                     URLQueryItem(name: "expiryTimestamp", value: String(expiryTimestamp))]
        if let relayData = relay.data {
            parts.append(URLQueryItem(name: "relay-data", value: relayData))
        }
        if let methods = methods {
            let encodedMethods = methods.joined(separator: ",")
            parts.append(URLQueryItem(name: "methods", value: encodedMethods))
        }
        var components = URLComponents()
        components.queryItems = parts
        return components.percentEncodedQuery ?? ""
    }

    private static func parseURIComponents(from string: String) -> URLComponents? {
        // Accept a fully encoded deep-link payload once, while leaving encoded
        // field contents in an ordinary wc: URI intact until query parsing.
        let decodedString = string.hasPrefix("wc:") ? string : (string.removingPercentEncoding ?? string)
        guard decodedString.hasPrefix("wc:") else {
            return nil
        }

        let urlString = !decodedString.hasPrefix("wc://") ? "wc://" + decodedString.dropFirst(3) : decodedString
        return URLComponents(string: urlString)
    }
}

extension WalletConnectURI.Errors: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .expired:
            return NSLocalizedString("The WalletConnect Pairing URI has expired.", comment: "Expired URI Error")
        case .invalidFormat:
            return NSLocalizedString("The format of the WalletConnect Pairing URI is invalid.", comment: "Invalid Format URI Error")
        }
    }
}


fileprivate var fiveMinutesFromNow: UInt64 {
    return UInt64(Date().timeIntervalSince1970) + 5 * 60
}


#if canImport(UIKit)

import UIKit

extension WalletConnectURI {
    public init(connectionOptions: UIScene.ConnectionOptions) throws {
        if let uri = connectionOptions.urlContexts.first?.url.query?.replacingOccurrences(of: "uri=", with: "") {
            try self.init(uriString: uri)
        } else {
            throw Errors.invalidFormat
        }
    }
    
    public init(urlContext: UIOpenURLContext) throws {
        if let uri = urlContext.url.query?.replacingOccurrences(of: "uri=", with: "") {
            try self.init(uriString: uri)
        } else {
            throw Errors.invalidFormat
        }
    }
}
#endif

#if DEBUG
extension WalletConnectURI {
    init(topic: String, symKey: String, relay: RelayProtocolOptions, methods: [String]? = nil, expiryTimestamp: UInt64) {
        self.version = "2"
        self.topic = topic
        self.symKey = symKey
        self.relay = relay
        self.methods = methods
        self.expiryTimestamp = expiryTimestamp
    }
}
#endif
