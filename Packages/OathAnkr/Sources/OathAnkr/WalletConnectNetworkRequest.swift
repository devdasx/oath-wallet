import Foundation

/// Only a chain already known to the wallet and approved in this session may
/// be selected. Peer-supplied RPC URLs are never used by this method.
public enum WalletConnectNetworkRequest {
    public enum Failure: Error, Equatable { case malformed, unauthorized }
    public static func chainID(params: Data, supported: Set<UInt64>, authorized: Set<UInt64>) throws -> UInt64 {
        guard case .array(let items) = try WalletConnectJSON.decode(params), items.count == 1,
              case .object(let object) = items[0], object.count == 1,
              let raw = object["chainId"]?.string, raw.hasPrefix("0x"), raw.count > 2, raw.count <= 18,
              raw.dropFirst(2).allSatisfy({ $0.isASCII && $0.isHexDigit }),
              raw.count == 3 || raw.dropFirst(2).first != "0",
              let id = UInt64(raw.dropFirst(2), radix: 16), id > 0 else { throw Failure.malformed }
        guard supported.contains(id), authorized.contains(id) else { throw Failure.unauthorized }
        return id
    }
}
