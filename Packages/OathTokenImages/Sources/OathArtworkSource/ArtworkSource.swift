import Foundation
import CryptoKit
import Darwin

/// Artwork identity is its full URI, never a ticker. Accept provider CDN hosts
/// without a chain-specific allowlist. Networking remains HTTPS and anonymous.
public enum ArtworkSource {
    public static let byteLimit = 8 * 1024 * 1024

    public static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= byteLimit * 2 else { return nil }
        if text.lowercased().hasPrefix("data:image/") { return inlineData(text) == nil ? nil : text }
        guard text.utf8.count <= 8192 else { return nil }
        guard var url = URLComponents(string: text) else { return nil }
        switch url.scheme?.lowercased() {
        case "ipfs":
            guard text.lowercased().hasPrefix("ipfs://") else { return nil }
            var path = String(text.dropFirst("ipfs://".count))
            if path.hasPrefix("ipfs/") { path.removeFirst(5) }
            guard !path.isEmpty, !path.contains("..") else { return nil }
            return normalized("https://ipfs.io/ipfs/" + path)
        case "ar":
            guard text.lowercased().hasPrefix("ar://"), text.count > 5 else { return nil }
            return normalized("https://arweave.net/" + text.dropFirst(5))
        case "http", "https": url.scheme = "https"
        default: return nil
        }
        guard let result = url.url, permits(result) else { return nil }
        return result.absoluteString
    }

    public static func permits(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = dnsName(url),
              host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(validDNSLabel),
              let suffix = labels.last, !suffix.utf8.allSatisfy({ (48...57).contains($0) }),
              !["localhost", "local", "internal", "home", "lan"].contains(suffix),
              host != "home.arpa", !host.hasSuffix(".home.arpa") else { return false }

        // Darwin accepts shortened, hexadecimal and mixed-base IPv4 literals.
        // Validate the whole decoded DNS name before passing it to a C-string API.
        var address = in_addr()
        return inet_aton(host, &address) == 0
    }

    private static func dnsName(_ url: URL) -> String? {
        guard let decoded = url.host?.lowercased() else { return nil }
        if decoded.utf8.allSatisfy({ $0 < 128 }) { return decoded }
        // Foundation leaves a percent-encoded international label decoded in
        // URL.host. Apply the same IDNA conversion as an ordinary Unicode URL.
        var authority = URLComponents()
        authority.scheme = "https"
        authority.host = decoded
        return authority.encodedHost
    }

    private static func validDNSLabel(_ label: Substring) -> Bool {
        guard (1...63).contains(label.utf8.count),
              label.first != "-", label.last != "-" else { return false }
        return label.utf8.allSatisfy { byte in
            (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
        }
    }

    public static func inlineData(_ value: String) -> Data? {
        guard value.utf8.count <= byteLimit * 2, let comma = value.firstIndex(of: ",") else { return nil }
        let header = value[..<comma].lowercased()
        guard ["data:image/png", "data:image/jpeg", "data:image/webp", "data:image/gif", "data:image/avif", "data:image/svg+xml"].contains(header.components(separatedBy: ";")[0]) else { return nil }
        let body = String(value[value.index(after: comma)...])
        let data = header.hasSuffix(";base64") ? Data(base64Encoded: body) : body.removingPercentEncoding?.data(using: .utf8)
        guard let data, !data.isEmpty, data.count <= byteLimit else { return nil }
        return data
    }

    public static func candidates(_ sources: [String]) -> [String] {
        var result: [String] = []
        for source in sources.prefix(4) {
            guard let source = normalized(source) else { continue }
            // TonAPI supplies signed 200px imgproxy thumbnails. Its encoded
            // source is the jetton's original image; retain the signed proxy
            // as fallback if that original is offline or unsupported.
            if let url = URL(string: source), url.host == "cache.tonapi.io", url.path.hasPrefix("/imgproxy/") {
                var encoded = String(url.lastPathComponent.split(separator: ".").first ?? "")
                    .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
                if let data = Data(base64Encoded: encoded), let text = String(data: data, encoding: .utf8),
                   let original = normalized(text), original.hasPrefix("https://"), !result.contains(original) {
                    result.append(original)
                }
            }
            if let url = URLComponents(string: source),
               ["assets.coingecko.com", "coin-images.coingecko.com"].contains(url.host ?? "") {
                var large = url
                large.path = url.path.replacingOccurrences(of: "/small/", with: "/large/")
                    .replacingOccurrences(of: "/thumb/", with: "/large/")
                if let upgraded = large.url?.absoluteString, !result.contains(upgraded) { result.append(upgraded) }
            }
            if !result.contains(source) { result.append(source) }
        }
        return result
    }

    public static func key(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
