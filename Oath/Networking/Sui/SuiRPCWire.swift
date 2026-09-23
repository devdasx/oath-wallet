import Foundation

/// Bounded protobuf projection of sui.rpc.v2. Unknown fields are skipped, never
/// interpreted as status or amounts. Field numbers follow MystenLabs/sui-apis.
enum SuiRPCWire {
    struct Field {
        let number: Int
        let bytes: Data?
        let integer: UInt64?
    }

    static func field(_ number: Int, _ bytes: Data) -> Data {
        var data = varint(UInt64(number << 3 | 2))
        data.append(varint(UInt64(bytes.count)))
        data.append(bytes)
        return data
    }

    static func fields(_ data: Data) throws -> [Field] {
        let bytes = [UInt8](data)
        var offset = 0
        var result: [Field] = []
        func readVarint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < bytes.count else { throw malformed() }
                let byte = bytes[offset]
                offset += 1
                guard shift != 63 || byte <= 1 else { throw malformed() }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw malformed()
        }
        while offset < bytes.count {
            let tag = try readVarint()
            guard tag >> 3 > 0, tag >> 3 < (1 << 29) else { throw malformed() }
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                result.append(Field(number: number, bytes: nil, integer: try readVarint()))
            case 2:
                let size = try readVarint()
                guard size <= UInt64(bytes.count - offset) else { throw malformed() }
                let end = offset + Int(size)
                result.append(Field(number: number, bytes: Data(bytes[offset..<end]), integer: nil))
                offset = end
            case 1, 5:
                let size = tag & 7 == 1 ? 8 : 4
                guard bytes.count - offset >= size else { throw malformed() }
                offset += size
            default: throw malformed()
            }
        }
        return result
    }

    static func bytes(_ number: Int, in data: Data) throws -> Data {
        let matches = try fields(data).filter { $0.number == number }
        guard matches.count == 1, let value = matches.first?.bytes else { throw malformed() }
        return value
    }

    static func text(_ number: Int, in data: Data) throws -> String {
        guard let value = String(data: try bytes(number, in: data), encoding: .utf8) else {
            throw malformed()
        }
        return value
    }

    static func executionRequest(transaction: String, signature: String) throws -> Data {
        guard let tx = Data(base64Encoded: transaction), !tx.isEmpty,
              let sig = Data(base64Encoded: signature), !sig.isEmpty,
              tx.count <= 131_072, sig.count <= 16_384 else { throw malformed() }
        // Transaction.bcs.value / UserSignature.bcs.value preserve Wallet Core bytes.
        let mask = field(1, Data("digest".utf8)) + field(1, Data("effects.status".utf8))
        return field(1, field(1, field(2, tx)))
            + field(2, field(1, field(2, sig))) + field(3, mask)
    }

    static func executionDigest(_ message: Data) throws -> String {
        let transaction = try bytes(1, in: message)
        let digest = try text(1, in: transaction)
        guard SendTransactionStatusValidation.isBase58Hash(digest, byteCount: 32) else {
            throw malformed()
        }
        let effects = try bytes(4, in: transaction)
        let status = try bytes(4, in: effects)
        let successes = try fields(status).filter { $0.number == 1 }
        guard successes.count == 1, let success = successes.first?.integer,
              success <= 1 else { throw malformed() }
        if success == 0 {
            // Preserve an actionable numeric protocol error, never remote free text.
            let error = try bytes(2, in: status)
            let kind = try fields(error).first { $0.number == 3 }?.integer
            throw SuiProviderError.executionFailed(
                code: "grpc_execution_\(kind.map(String.init) ?? "failed")", digest: digest
            )
        }
        return digest
    }

    static func frame(_ message: Data) -> Data {
        let count = UInt32(message.count)
        return Data([0, UInt8(count >> 24), UInt8((count >> 16) & 255),
                     UInt8((count >> 8) & 255), UInt8(count & 255)]) + message
    }

    static func response(_ data: Data, http: HTTPURLResponse) throws -> Data {
        guard data.count <= 1_048_576 else { throw malformed() }
        var offset = 0
        let raw = [UInt8](data)
        var message: Data?
        var status = http.value(forHTTPHeaderField: "grpc-status").flatMap(Int.init)
        var hasTrailers = false
        while offset < raw.count {
            guard !hasTrailers, raw.count - offset >= 5 else { throw malformed() }
            let flag = raw[offset]
            let length = raw[(offset + 1)..<(offset + 5)].reduce(0) { $0 * 256 + Int($1) }
            offset += 5
            guard length <= raw.count - offset else { throw malformed() }
            let payload = Data(raw[offset..<(offset + length)])
            offset += length
            if flag == 0x80 {
                hasTrailers = true
                guard let trailers = String(data: payload, encoding: .utf8) else { throw malformed() }
                for line in trailers.components(separatedBy: "\r\n") {
                    let pair = line.split(separator: ":", maxSplits: 1)
                    if pair.count == 2, pair[0].lowercased() == "grpc-status" {
                        guard let value = Int(pair[1].trimmingCharacters(in: .whitespaces)),
                              status == nil || status == value else { throw malformed() }
                        status = value
                    }
                }
            } else if flag == 0, message == nil {
                message = payload
            } else { throw malformed() }
        }
        if let status, status != 0 { throw SuiProviderError.grpc(status: status) }
        // Native gRPC gateways may strip HTTP trailers. A fully decoded receipt
        // still proves execution; an empty/malformed response never does.
        let isNativeGRPC = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first == "application/grpc"
        guard status == 0 || isNativeGRPC, let message else { throw malformed() }
        return message
    }

    private static func varint(_ value: UInt64) -> Data {
        var remaining = value
        var bytes = Data()
        repeat {
            let byte = UInt8(remaining & 127)
            remaining >>= 7
            bytes.append(byte | (remaining == 0 ? 0 : 128))
        } while remaining > 0
        return bytes
    }

    private static func malformed() -> SuiProviderError {
        .invalidResponse("grpc_payload")
    }
}
