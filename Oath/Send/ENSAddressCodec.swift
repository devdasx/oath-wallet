import Foundation
import WalletCore

enum ENSAddressCodec {
    static let supportedNetworkIDs: [String] = {
        let evmNetworkIDs = Set(
            SendAddressValidator.evmNetworks.map(\.id)
        )
        let receiveNetworkIDs = ReceiveNetworkCatalog.all
            .map(\.id)
            .filter {
                evmNetworkIDs.contains($0)
                    || $0 == TronConstants.networkID
                    || $0 == SolanaConstants.networkID
            }
        return receiveNetworkIDs
            + BitcoinFamilyChain.allCases.map(\.networkID)
    }()

    static func coinType(for networkID: String) -> UInt64? {
        switch networkID {
        case BitcoinFamilyChain.bitcoin.networkID:
            return 0
        case BitcoinFamilyChain.litecoin.networkID:
            return 2
        case BitcoinFamilyChain.dogecoin.networkID:
            return 3
        case BitcoinFamilyChain.bitcoinCash.networkID:
            return 145
        case TronConstants.networkID:
            return 195
        case SolanaConstants.networkID:
            return 501
        case "eth":
            return 60
        default:
            guard
                let network = SendAddressValidator.evmNetworks.first(
                    where: { $0.id == networkID }
                ),
                network.chainID > 0
            else {
                return nil
            }
            return 0x8000_0000 | UInt64(network.chainID)
        }
    }

    static func address(
        from record: Data,
        networkID: String
    ) throws -> String {
        let address: String
        if SendAddressValidator.evmNetworks.contains(
            where: { $0.id == networkID }
        ) {
            guard record.count == 20 else {
                throw SendRecipientNameError.invalidServiceResponse
            }
            address = "0x" + record.hexString
        } else {
            switch networkID {
            case SolanaConstants.networkID:
                guard record.count == 32 else {
                    throw SendRecipientNameError.invalidServiceResponse
                }
                address = Base58.encodeNoCheck(data: record)
            case TronConstants.networkID:
                guard record.count == 21, record.first == 0x41 else {
                    throw SendRecipientNameError.invalidServiceResponse
                }
                address = Base58.encode(data: record)
            case BitcoinFamilyChain.bitcoin.networkID,
                 BitcoinFamilyChain.bitcoinCash.networkID,
                 BitcoinFamilyChain.litecoin.networkID,
                 BitcoinFamilyChain.dogecoin.networkID:
                guard let chain = BitcoinFamilyChain(
                    rawValue: networkID
                ), let resolved = BitcoinFamilyScriptAddress.address(
                    from: record,
                    chain: chain
                ) else {
                    throw SendRecipientNameError.invalidServiceResponse
                }
                address = resolved
            default:
                throw SendRecipientNameError.networkMismatch
            }
        }
        guard SendAddressValidator.isValid(address, for: networkID) else {
            throw SendRecipientNameError.invalidResolvedAddress
        }
        return address
    }

    private static func bitcoinFamilyAddress(
        from script: Data,
        chain: BitcoinFamilyChain
    ) throws -> String {
        if let hash = p2pkhHash(in: script) {
            let prefix: UInt8
            switch chain {
            case .bitcoin: prefix = 0x00
            case .litecoin: prefix = 0x30
            case .dogecoin: prefix = 0x1e
            case .bitcoinCash:
                throw SendRecipientNameError.invalidServiceResponse
            }
            return Base58.encode(data: Data([prefix]) + hash)
        }
        if let hash = p2shHash(in: script) {
            let prefix: UInt8
            switch chain {
            case .bitcoin: prefix = 0x05
            case .litecoin: prefix = 0x32
            case .dogecoin: prefix = 0x16
            case .bitcoinCash:
                throw SendRecipientNameError.invalidServiceResponse
            }
            return Base58.encode(data: Data([prefix]) + hash)
        }
        if let witness = witnessProgram(in: script) {
            let humanReadablePart: String
            switch chain {
            case .bitcoin:
                humanReadablePart = "bc"
            case .litecoin:
                humanReadablePart = "ltc"
            case .dogecoin, .bitcoinCash:
                throw SendRecipientNameError.invalidServiceResponse
            }
            return try SegwitAddressEncoder.encode(
                humanReadablePart: humanReadablePart,
                version: witness.version,
                program: witness.program
            )
        }
        throw SendRecipientNameError.invalidServiceResponse
    }

    private static func bitcoinCashAddress(
        from script: Data
    ) throws -> String {
        if let hash = p2pkhHash(in: script) {
            return try CashAddressEncoder.encode(
                prefix: "bitcoincash",
                type: 0,
                hash: hash
            )
        }
        if let hash = p2shHash(in: script) {
            return try CashAddressEncoder.encode(
                prefix: "bitcoincash",
                type: 1,
                hash: hash
            )
        }
        throw SendRecipientNameError.invalidServiceResponse
    }

    private static func p2pkhHash(in script: Data) -> Data? {
        guard
            script.count == 25,
            script.starts(with: [0x76, 0xa9, 0x14]),
            script.suffix(2) == Data([0x88, 0xac])
        else {
            return nil
        }
        return script.subdata(in: 3..<23)
    }

    private static func p2shHash(in script: Data) -> Data? {
        guard
            script.count == 23,
            script.starts(with: [0xa9, 0x14]),
            script.last == 0x87
        else {
            return nil
        }
        return script.subdata(in: 2..<22)
    }

    private static func witnessProgram(
        in script: Data
    ) -> (version: Int, program: Data)? {
        guard script.count >= 4 else { return nil }
        let version: Int
        switch script[script.startIndex] {
        case 0x00:
            version = 0
        case 0x51...0x60:
            version = Int(script[script.startIndex] - 0x50)
        default:
            return nil
        }
        let length = Int(script[script.startIndex + 1])
        guard
            (2...40).contains(length),
            script.count == length + 2
        else {
            return nil
        }
        return (
            version,
            script.subdata(in: 2..<(length + 2))
        )
    }
}

private enum SegwitAddressEncoder {
    private static let charset = Array(
        "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    )

    static func encode(
        humanReadablePart: String,
        version: Int,
        program: Data
    ) throws -> String {
        guard
            (0...16).contains(version),
            (2...40).contains(program.count),
            version != 0 || program.count == 20 || program.count == 32,
            let converted = convertBits(
                Array(program),
                from: 8,
                to: 5,
                pad: true
            )
        else {
            throw SendRecipientNameError.invalidServiceResponse
        }
        let values = [UInt8(version)] + converted
        let constant: UInt32 = version == 0 ? 1 : 0x2bc8_30a3
        let checksum = createChecksum(
            humanReadablePart: humanReadablePart,
            values: values,
            constant: constant
        )
        return humanReadablePart + "1"
            + String((values + checksum).map {
                charset[Int($0)]
            })
    }

    private static func createChecksum(
        humanReadablePart: String,
        values: [UInt8],
        constant: UInt32
    ) -> [UInt8] {
        let expanded = humanReadablePart.utf8.map { $0 >> 5 }
            + [0]
            + humanReadablePart.utf8.map { $0 & 31 }
        let polymod = polymod(
            expanded + values + Array(repeating: 0, count: 6)
        ) ^ constant
        return (0..<6).map {
            UInt8((polymod >> UInt32(5 * (5 - $0))) & 31)
        }
    }

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let generators: [UInt32] = [
            0x3b6a_57b2,
            0x2650_8e6d,
            0x1ea1_19fa,
            0x3d42_33dd,
            0x2a14_62b3
        ]
        return values.reduce(1) { checksum, value in
            let top = checksum >> 25
            var next = (checksum & 0x01ff_ffff) << 5
                ^ UInt32(value)
            for index in 0..<5 where (top >> index) & 1 == 1 {
                next ^= generators[index]
            }
            return next
        }
    }

    fileprivate static func convertBits(
        _ values: [UInt8],
        from sourceBits: Int,
        to destinationBits: Int,
        pad: Bool
    ) -> [UInt8]? {
        var accumulator = 0
        var bits = 0
        var result: [UInt8] = []
        let maximumValue = (1 << destinationBits) - 1
        for value in values {
            guard Int(value) >> sourceBits == 0 else { return nil }
            accumulator = (accumulator << sourceBits) | Int(value)
            bits += sourceBits
            while bits >= destinationBits {
                bits -= destinationBits
                result.append(
                    UInt8((accumulator >> bits) & maximumValue)
                )
            }
        }
        if pad {
            if bits > 0 {
                result.append(
                    UInt8(
                        (accumulator << (destinationBits - bits))
                            & maximumValue
                    )
                )
            }
        } else if bits >= sourceBits
            || ((accumulator << (destinationBits - bits))
                & maximumValue) != 0 {
            return nil
        }
        return result
    }
}

private enum CashAddressEncoder {
    private static let charset = Array(
        "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    )

    static func encode(
        prefix: String,
        type: UInt8,
        hash: Data
    ) throws -> String {
        guard
            let sizeBits = sizeBits(for: hash.count),
            type <= 15,
            let converted = SegwitAddressEncoder.convertBits(
                [type << 3 | sizeBits] + Array(hash),
                from: 8,
                to: 5,
                pad: true
            )
        else {
            throw SendRecipientNameError.invalidServiceResponse
        }
        let checksum = createChecksum(
            prefix: prefix,
            payload: converted
        )
        return prefix + ":"
            + String((converted + checksum).map {
                charset[Int($0)]
            })
    }

    private static func sizeBits(for byteCount: Int) -> UInt8? {
        switch byteCount {
        case 20: 0
        case 24: 1
        case 28: 2
        case 32: 3
        case 40: 4
        case 48: 5
        case 56: 6
        case 64: 7
        default: nil
        }
    }

    private static func createChecksum(
        prefix: String,
        payload: [UInt8]
    ) -> [UInt8] {
        let values = prefix.utf8.map { $0 & 31 }
            + [0]
            + payload
            + Array(repeating: 0, count: 8)
        let checksum = polymod(values) ^ 1
        return (0..<8).map {
            UInt8(
                (checksum >> UInt64(5 * (7 - $0))) & 31
            )
        }
    }

    private static func polymod(_ values: [UInt8]) -> UInt64 {
        let generators: [UInt64] = [
            0x98f2_bc8e_61,
            0x79b7_6d99_e2,
            0xf33e_5fb3_c4,
            0xae2e_abe2_a8,
            0x1e4f_43e4_70
        ]
        return values.reduce(1) { checksum, value in
            let top = checksum >> 35
            var next = (checksum & 0x07_ffff_ffff) << 5
                ^ UInt64(value)
            for index in 0..<5 where (top >> index) & 1 == 1 {
                next ^= generators[index]
            }
            return next
        }
    }
}
