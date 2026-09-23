import CryptoKit
import Foundation

extension AssetPriceClient {
    /// Some on-chain price APIs expose the chain's canonical contract-like
    /// identifier instead of the wallet-facing issued-asset identity. The
    /// conversion remains deterministic and local so a quote can still be
    /// verified against the exact requested asset.
    static func onChainProviderTokenAddress(
        for asset: WalletAsset
    ) -> String? {
        guard let contract = priceContractAddress(for: asset),
              let network = asset.network else {
            return nil
        }
        switch network {
        case .stellar:
            return StellarAssetContractPriceIdentity.contractID(
                contractAddress: contract
            )
        case .xrp:
            return XRPIssuedAssetPriceIdentity.providerAddress(
                contractAddress: contract
            )
        default:
            return contract
        }
    }
}

private enum StellarAssetContractPriceIdentity {
    private static let envelopeTypeContractID: UInt32 = 8
    private static let contractPreimageFromAsset: UInt32 = 1
    private static let publicKeyTypeED25519: UInt32 = 0
    private static let contractStrKeyVersion: UInt8 = 2 << 3
    private static let base32Alphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    )

    static func contractID(contractAddress: String) -> String? {
        guard let asset = StellarAssetIdentity.validated(
            contractAddress: contractAddress
        ), let issuer = try? StellarTransactionXDRBuilder.accountIDBytes(
            asset.issuer
        ), issuer.count == 32 else {
            return nil
        }

        var preimage = Data()
        appendXDR(envelopeTypeContractID, to: &preimage)
        preimage.append(
            contentsOf: SHA256.hash(
                data: Data(StellarConstants.networkPassphrase.utf8)
            )
        )
        appendXDR(contractPreimageFromAsset, to: &preimage)

        let code = Data(asset.code.utf8)
        switch code.count {
        case 1...4:
            appendXDR(1, to: &preimage)
            preimage.append(code)
            preimage.append(Data(repeating: 0, count: 4 - code.count))
        case 5...12:
            appendXDR(2, to: &preimage)
            preimage.append(code)
            preimage.append(Data(repeating: 0, count: 12 - code.count))
        default:
            return nil
        }
        appendXDR(publicKeyTypeED25519, to: &preimage)
        preimage.append(issuer)

        var encoded = Data([contractStrKeyVersion])
        encoded.append(contentsOf: SHA256.hash(data: preimage))
        let checksum = crc16XModem(encoded)
        encoded.append(UInt8(checksum & 0x00FF))
        encoded.append(UInt8(checksum >> 8))
        return base32(encoded)
    }

    private static func appendXDR(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) {
            data.append(contentsOf: $0)
        }
    }

    private static func crc16XModem(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0
                    ? (crc << 1) ^ 0x1021
                    : crc << 1
            }
        }
        return crc
    }

    private static func base32(_ data: Data) -> String {
        var result = ""
        var buffer = 0
        var bitCount = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                result.append(
                    base32Alphabet[(buffer >> bitCount) & 0x1F]
                )
                buffer &= (1 << bitCount) - 1
            }
        }
        if bitCount > 0 {
            result.append(base32Alphabet[(buffer << (5 - bitCount)) & 0x1F])
        }
        return result
    }
}

private enum XRPIssuedAssetPriceIdentity {
    static func providerAddress(contractAddress: String) -> String? {
        let pieces = contractAddress.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard pieces.count == 2 else { return nil }
        let currency = String(pieces[0]).uppercased()
        let issuer = String(pieces[1])
        guard XRPAddress.validatedClassic(issuer) != nil,
              let currencyHex = encodedCurrency(currency) else {
            return nil
        }
        return currencyHex + "." + issuer
    }

    private static func encodedCurrency(_ currency: String) -> String? {
        if currency.utf8.count == 40,
           currency.unicodeScalars.allSatisfy({ scalar in
               CharacterSet(charactersIn: "0123456789ABCDEF")
                   .contains(scalar)
           }) {
            return currency
        }
        let code = Array(currency.utf8)
        guard (1...20).contains(code.count),
              code.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }) else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: 20)
        if code.count == 3 {
            bytes.replaceSubrange(12..<15, with: code)
        } else {
            bytes.replaceSubrange(0..<code.count, with: code)
        }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }
}
