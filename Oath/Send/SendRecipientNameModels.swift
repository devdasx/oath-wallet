import Foundation

enum SendRecipientNameService: Hashable, Sendable {
    case ens
    case solanaNameService
    case spaceIDDomain
    case spaceIDPaymentID
}

struct SendRecipientNameDescriptor: Hashable, Sendable {
    let input: String
    let service: SendRecipientNameService
    let candidateNetworkIDs: [String]
}

enum SendRecipientNameError: Error, Hashable, Sendable {
    case invalidName
    case unsupportedService
    case ensUsesEthSuffix
    case networkMismatch
    case notFound
    case noRecordForNetwork
    case serviceUnavailable
    case invalidServiceResponse
    case invalidResolvedAddress

    var localizedMessage: String {
        WalletLocalization.string(localizationKey)
    }

    private var localizationKey: String {
        switch self {
        case .invalidName:
            "send.recipient.error.invalid_name"
        case .unsupportedService:
            "send.recipient.error.unsupported_name_service"
        case .ensUsesEthSuffix:
            "send.recipient.error.ens_uses_eth"
        case .networkMismatch:
            "send.recipient.error.name_network_mismatch"
        case .notFound:
            "send.recipient.error.name_not_found"
        case .noRecordForNetwork:
            "send.recipient.error.name_record_missing"
        case .serviceUnavailable:
            "send.recipient.error.name_service_unavailable"
        case .invalidServiceResponse:
            "send.recipient.error.name_service_response"
        case .invalidResolvedAddress:
            "send.recipient.error.resolved_address_invalid"
        }
    }
}

enum SendRecipientNameParser {
    private static let maximumInputBytes = 255

    private static let spaceIDNetworkBySuffix: [String: String] = [
        "bnb": "bsc",
        "four": "bsc",
        "arb": "arbitrum",
        "gno": "gnosis",
        "taiko": "taiko"
    ]

    static func descriptor(
        for rawInput: String
    ) throws -> SendRecipientNameDescriptor? {
        let input = rawInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !input.isEmpty else {
            throw SendRecipientNameError.invalidName
        }
        guard
            input.utf8.count <= maximumInputBytes,
            !input.contains(where: {
                $0.isWhitespace || $0.isNewline
                    || $0.unicodeScalars.contains(where: {
                        CharacterSet.controlCharacters.contains($0)
                    })
            }),
            !input.contains("?"),
            !input.contains("#"),
            !input.contains("/")
        else {
            throw SendRecipientNameError.invalidName
        }

        if input.contains("@") {
            return try paymentIDDescriptor(input)
        }
        guard input.contains(".") else { return nil }

        let labels = input.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard
            labels.count >= 2,
            labels.allSatisfy({ !$0.isEmpty }),
            let suffix = labels.last?.lowercased()
        else {
            throw SendRecipientNameError.invalidName
        }

        if suffix == "ens" {
            throw SendRecipientNameError.ensUsesEthSuffix
        }
        if suffix == "eth" {
            return SendRecipientNameDescriptor(
                input: input,
                service: .ens,
                candidateNetworkIDs: ENSAddressCodec.supportedNetworkIDs
            )
        }
        if suffix == "sol" {
            return SendRecipientNameDescriptor(
                input: input,
                service: .solanaNameService,
                candidateNetworkIDs: [SolanaConstants.networkID]
            )
        }
        if let networkID = spaceIDNetworkBySuffix[suffix] {
            return SendRecipientNameDescriptor(
                input: input,
                service: .spaceIDDomain,
                candidateNetworkIDs: [networkID]
            )
        }
        throw SendRecipientNameError.unsupportedService
    }

    static func issue(
        for input: String,
        networkID: String
    ) -> SendRecipientNameError? {
        do {
            guard let descriptor = try descriptor(for: input) else {
                return nil
            }
            guard descriptor.candidateNetworkIDs.contains(networkID) else {
                return .networkMismatch
            }
            return nil
        } catch let error as SendRecipientNameError {
            return error
        } catch {
            return .invalidName
        }
    }

    private static func paymentIDDescriptor(
        _ input: String
    ) throws -> SendRecipientNameDescriptor {
        let pieces = input.split(
            separator: "@",
            omittingEmptySubsequences: false
        )
        guard
            pieces.count == 2,
            pieces.allSatisfy({ !$0.isEmpty }),
            pieces[1].allSatisfy(isPaymentProviderCharacter)
        else {
            throw SendRecipientNameError.invalidName
        }
        return SendRecipientNameDescriptor(
            input: input,
            service: .spaceIDPaymentID,
            candidateNetworkIDs: paymentIDNetworkIDs
        )
    }

    private static func isPaymentProviderCharacter(
        _ character: Character
    ) -> Bool {
        character.isASCII
            && (
                character.isLetter
                    || character.isNumber
                    || character == "-"
                    || character == "_"
                    || character == "."
            )
    }

    private static var paymentIDNetworkIDs: [String] {
        SendAddressValidator.evmNetworks.map(\.id)
            + [
                BitcoinFamilyChain.bitcoin.networkID,
                SolanaConstants.networkID,
                TronConstants.networkID
            ]
    }
}
