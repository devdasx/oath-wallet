import Foundation
import WalletCore

struct CustomEVMToken: Hashable, Sendable {
    let network: ReceiveNetwork
    let contractAddress: String
    let name: String
    let symbol: String
    let decimals: Int
    let logoSource: AssetLogoSource
    let usdPrice: Decimal?

    var assetID: String {
        "\(network.id):\(contractAddress.lowercased())"
    }
}

struct CustomSolanaToken: Sendable {
    let network: ReceiveNetwork
    let mintAddress: String
    let name: String
    let symbol: String
    let decimals: Int
    let logoSource: AssetLogoSource
    let eligibility: SolanaTokenEligibility

    var assetID: String {
        AssetIdentityKey.make(
            networkID: network.id,
            contractAddress: mintAddress
        )
    }
}

struct CustomTronToken: Sendable {
    let network: ReceiveNetwork
    let contractAddress: String
    let name: String
    let symbol: String
    let decimals: Int
    let logoSource: AssetLogoSource

    var assetID: String {
        AssetIdentityKey.make(
            networkID: network.id,
            contractAddress: contractAddress
        )
    }
}

enum CustomToken: Sendable {
    case evm(CustomEVMToken)
    case solana(CustomSolanaToken)
    case tron(CustomTronToken)

    var network: ReceiveNetwork {
        switch self {
        case let .evm(token): token.network
        case let .solana(token): token.network
        case let .tron(token): token.network
        }
    }

    var address: String {
        switch self {
        case let .evm(token): token.contractAddress
        case let .solana(token): token.mintAddress
        case let .tron(token): token.contractAddress
        }
    }

    var name: String {
        switch self {
        case let .evm(token): token.name
        case let .solana(token): token.name
        case let .tron(token): token.name
        }
    }

    var symbol: String {
        switch self {
        case let .evm(token): token.symbol
        case let .solana(token): token.symbol
        case let .tron(token): token.symbol
        }
    }

    var decimals: Int {
        switch self {
        case let .evm(token): token.decimals
        case let .solana(token): token.decimals
        case let .tron(token): token.decimals
        }
    }

    var logoSource: AssetLogoSource {
        switch self {
        case let .evm(token): token.logoSource
        case let .solana(token): token.logoSource
        case let .tron(token): token.logoSource
        }
    }

    var usdPrice: Decimal? {
        guard case let .evm(token) = self else { return nil }
        return token.usdPrice
    }

    var assetID: String {
        switch self {
        case let .evm(token): token.assetID
        case let .solana(token): token.assetID
        case let .tron(token): token.assetID
        }
    }
}

enum CustomTokenAddress {
    static func supports(networkID: String) -> Bool {
        AnkrAPIClient.supportsTokenLookup(networkID: networkID)
            || networkID == SolanaConstants.networkID
            || networkID == TronConstants.networkID
    }

    static func normalized(
        _ value: String,
        networkID: String
    ) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        switch networkID {
        case SolanaConstants.networkID:
            return CoinType.solana.validate(address: trimmed)
                ? trimmed : nil
        case TronConstants.networkID:
            return TronValueParser.isValidMainnetAddress(trimmed)
                ? trimmed : nil
        default:
            let lowercasePrefix = trimmed.hasPrefix("0X")
                ? "0x" + trimmed.dropFirst(2) : trimmed
            let normalized = lowercasePrefix.lowercased()
            guard
                AnkrAPIClient.supportsTokenLookup(networkID: networkID),
                AnkrAPIClient.isValidAddress(normalized),
                normalized
                    != "0x0000000000000000000000000000000000000000"
            else {
                return nil
            }
            return normalized
        }
    }

    static func sanitizedInput(
        _ value: String,
        networkID: String
    ) -> String {
        switch networkID {
        case SolanaConstants.networkID:
            return String(
                value.filter(Self.isBase58Character).prefix(44)
            )
        case TronConstants.networkID:
            return String(
                value.filter(Self.isBase58Character).prefix(34)
            )
        default:
            let filtered = value.filter { character in
                character.isASCII
                    && (
                        character.isHexDigit
                            || character == "x"
                            || character == "X"
                    )
            }
            return String(filtered.prefix(42))
        }
    }

    static func extracted(
        from payload: String,
        networkID: String
    ) -> String? {
        let decoded = payload.removingPercentEncoding ?? payload
        if let direct = normalized(decoded, networkID: networkID) {
            return direct
        }
        let pattern: String
        switch networkID {
        case SolanaConstants.networkID:
            pattern = #"[1-9A-HJ-NP-Za-km-z]{32,44}"#
        case TronConstants.networkID:
            pattern = #"[1-9A-HJ-NP-Za-km-z]{34}"#
        default:
            pattern = #"0[xX][0-9a-fA-F]{40}"#
        }
        guard let expression = try? NSRegularExpression(pattern: pattern)
        else {
            return nil
        }
        let range = NSRange(decoded.startIndex..., in: decoded)
        for match in expression.matches(in: decoded, range: range) {
            guard let matchRange = Range(match.range, in: decoded) else {
                continue
            }
            if let normalized = normalized(
                String(decoded[matchRange]),
                networkID: networkID
            ) {
                return normalized
            }
        }
        return nil
    }

    static func isCompleteInvalidCandidate(
        _ value: String,
        networkID: String
    ) -> Bool {
        switch networkID {
        case SolanaConstants.networkID:
            value.count >= 44
        case TronConstants.networkID:
            value.count >= 34
        default:
            value.count >= 42
        }
    }

    private static let base58Characters = Set(
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    )

    private static func isBase58Character(_ character: Character) -> Bool {
        base58Characters.contains(character)
    }
}
