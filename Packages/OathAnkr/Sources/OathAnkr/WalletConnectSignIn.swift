import Foundation

/// A strict ERC-4361 parser for the ordinary HTTPS sign-in form. A recognizable
/// but invalid sign-in is rejected, never downgraded to a generic sign request.
/// Original message bytes remain the sole input to EIP-191 signing.
public struct WalletConnectSignIn: Sendable, Equatable {
    public enum Failure: Error, Sendable { case malformed, wrongOrigin, wrongAccount, wrongChain, expired, notYetValid }
    public let domain: String, address: String, uri: String, nonce: String
    public let statement: String?
    public let issuedAt: Date, expiration: Date?, notBefore: Date?
    public let requestID: String?
    public let resources: [String]
    public let chainID: UInt64
    private static let marker = " wants you to sign in with your Ethereum account:"

    public static func parse(_ message: Data, account: String, chainID: UInt64, website: String, now: Date = .now) throws -> Self? {
        guard let text = String(data: message, encoding: .utf8), text.contains(marker) else { return nil }
        guard message.count <= 4_096, text.utf8.allSatisfy({ $0 == 10 || (32...126).contains($0) }) else { throw Failure.malformed }
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 9, lines[0].hasSuffix(marker), lines[2].isEmpty else { throw Failure.malformed }
        let authority = String(lines[0].dropLast(marker.count))
        let rawOrigin = authority.contains("://") ? authority : "https://" + authority
        guard let origin = httpsOrigin(rawOrigin), let expected = httpsOrigin(website), origin == expected,
              let parts = URLComponents(string: rawOrigin), parts.path.isEmpty, parts.query == nil, parts.fragment == nil else { throw Failure.wrongOrigin }
        let address = lines[1]
        guard address.count == 42, address.hasPrefix("0x"), address.dropFirst(2).utf8.allSatisfy(isHex),
              address.lowercased() == account.lowercased() else { throw Failure.wrongAccount }
        var index = 3
        let statement: String?
        if lines[index].isEmpty { statement = nil }
        else { statement = lines[index]; index += 1 }
        guard lines.indices.contains(index), lines[index].isEmpty else { throw Failure.malformed }; index += 1
        func required(_ prefix: String) throws -> String {
            guard lines.indices.contains(index), lines[index].hasPrefix(prefix) else { throw Failure.malformed }
            let result = String(lines[index].dropFirst(prefix.count)); index += 1
            guard !result.isEmpty else { throw Failure.malformed }; return result
        }
        let uri = try required("URI: ")
        guard httpsOrigin(uri) == expected else { throw Failure.wrongOrigin }
        guard try required("Version: ") == "1" else { throw Failure.malformed }
        let chain = try required("Chain ID: ")
        guard chain.utf8.allSatisfy({ (48...57).contains($0) }), let parsedChain = UInt64(chain), parsedChain == chainID else { throw Failure.wrongChain }
        let nonce = try required("Nonce: ")
        guard nonce.count >= 8, nonce.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw Failure.malformed }
        guard let issued = date(try required("Issued At: ")) else { throw Failure.malformed }
        func optional(_ prefix: String) -> String? {
            guard lines.indices.contains(index), lines[index].hasPrefix(prefix) else { return nil }
            let result = String(lines[index].dropFirst(prefix.count)); index += 1; return result
        }
        let rawExpiration = optional("Expiration Time: "), rawNotBefore = optional("Not Before: ")
        let expiration = rawExpiration.flatMap(date), notBefore = rawNotBefore.flatMap(date)
        guard rawExpiration == nil || expiration != nil, rawNotBefore == nil || notBefore != nil else { throw Failure.malformed }
        let requestID = optional("Request ID: ")
        guard requestID == nil || requestID!.utf8.allSatisfy({ ![32, 34, 60, 62, 92, 94, 96, 123, 124, 125].contains($0) }) else { throw Failure.malformed }
        var resources = [String]()
        if lines.indices.contains(index), lines[index] == "Resources:" {
            index += 1
            while lines.indices.contains(index) {
                let resource = try required("- ")
                guard resources.count < 32, !resource.contains(" "), let url = URLComponents(string: resource),
                      url.scheme != nil, url.user == nil, url.password == nil else { throw Failure.malformed }
                resources.append(resource)
            }
        }
        guard index == lines.count, expiration == nil || expiration! >= issued,
              notBefore == nil || expiration == nil || notBefore! <= expiration! else { throw Failure.malformed }
        let result = Self(domain: origin, address: address, uri: uri, nonce: nonce, statement: statement,
                          issuedAt: issued, expiration: expiration, notBefore: notBefore, requestID: requestID,
                          resources: resources, chainID: parsedChain)
        try result.validateTime(now: now)
        return result
    }
    public func validateTime(now: Date = .now) throws {
        if let expiration, now >= expiration { throw Failure.expired }
        if let notBefore, now < notBefore { throw Failure.notYetValid }
        // Allow a small clock skew, but never show a future-issued login as current.
        if issuedAt > now.addingTimeInterval(300) { throw Failure.notYetValid }
    }
    private static func httpsOrigin(_ value: String) -> String? {
        guard let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, let host = parts.host?.lowercased(), !host.isEmpty,
              !host.hasSuffix("."), !host.contains(":"), host.utf8.allSatisfy({ $0 < 128 }),
              parts.port == nil || (1...65_535).contains(parts.port!) else { return nil }
        return host + ((parts.port == nil || parts.port == 443) ? "" : ":\(parts.port!)")
    }
    private static func isHex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }
    private static func date(_ value: String) -> Date? {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        if value.contains(".") { formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
        return formatter.date(from: value)
    }
}
