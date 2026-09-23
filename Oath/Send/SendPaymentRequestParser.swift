import Foundation
import WalletCore

enum SendPaymentRequestParser {
    private static let maximumPayloadBytes = 4_096
    private static let maximumMetadataBytes = 500

    static func parse(_ payload: String) throws -> SendPaymentRequest {
        let trimmed = payload.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            throw SendPaymentRequestError.emptyPayload
        }
        guard trimmed.utf8.count <= maximumPayloadBytes else {
            throw SendPaymentRequestError.payloadTooLarge
        }

        guard let separator = trimmed.firstIndex(of: ":") else {
            return try parseBareAddress(trimmed)
        }
        let scheme = trimmed[..<separator].lowercased()
        let body = String(trimmed[trimmed.index(after: separator)...])

        switch scheme {
        case "bitcoin":
            return try parseBitcoinFamilyURI(
                body,
                chain: .bitcoin,
                source: .bitcoinURI
            )
        case "bitcoincash":
            return try parseBitcoinFamilyURI(
                body,
                chain: .bitcoinCash,
                source: .bitcoinCashURI
            )
        case "litecoin":
            return try parseBitcoinFamilyURI(
                body,
                chain: .litecoin,
                source: .litecoinURI
            )
        case "dogecoin":
            return try parseBitcoinFamilyURI(
                body,
                chain: .dogecoin,
                source: .dogecoinURI
            )
        case "ethereum":
            return try parseEthereumURI(body)
        case "solana":
            return try parseSolanaPayURI(body)
        case "tron":
            return try parseTronURI(body)
        case "ton":
            return try parseTONURI(body)
        case "sui":
            return try parseSuiURI(body)
        case "aptos":
            return try parseAptosURI(body)
        case "near":
            return try parseNEARURI(body)
        case "xrp":
            return try parseXRPURI(body)
        case "web+stellar":
            return try parseStellarURI(body)
        default:
            throw SendPaymentRequestError.unsupportedScheme
        }
    }

    private static func parseAptosURI(
        _ body: String
    ) throws -> SendPaymentRequest {
        let uri = try SendURIComponents(body: body)
        guard let address = AptosAddress.canonical(uri.path) else {
            throw SendPaymentRequestError.invalidMainnetAddress
        }
        try uri.rejectDuplicateParameters(named: ["amount", "asset"])
        try uri.rejectParameters(except: ["amount", "asset"])
        let amount = try uri.firstValue(named: "amount").map {
            SendRequestedAmount.userUnits(
                try SendDecimalAmount.parseUserUnits(
                    $0,
                    maximumFractionDigits: AptosConstants.decimals
                ).canonical
            )
        }
        let requestedAsset: SendRequestedAsset
        if let rawAsset = uri.firstValue(named: "asset") {
            guard let canonical = AptosAssetType.canonical(rawAsset),
                  let assetID = AptosAssetType.assetID(canonical)
            else {
                throw SendPaymentRequestError.invalidContractAddress
            }
            requestedAsset = assetID == AptosConstants.nativeAssetID
                ? .native
                : .contract(canonical)
        } else {
            requestedAsset = .native
        }
        return SendPaymentRequest(
            source: .aptosURI,
            recipient: address,
            candidateNetworkIDs: [AptosConstants.networkID],
            requestedNetworkID: AptosConstants.networkID,
            requestedAsset: requestedAsset,
            requestedAmount: amount,
            label: nil,
            message: nil,
            memo: nil,
            references: []
        )
    }

    private static func parseBareAddress(
        _ address: String
    ) throws -> SendPaymentRequest {
        guard
            !address.contains("?"),
            !address.contains("#"),
            !address.contains("/")
        else {
            throw SendPaymentRequestError.unsupportedFormat
        }

        if let nameRequest = try preferredNameRequest(for: address) {
            return nameRequest
        }

        let candidates = SendAddressValidator.candidateNetworkIDs(
            for: address
        )
        if candidates.isEmpty {
            guard
                let descriptor = try SendRecipientNameParser.descriptor(
                    for: address
                )
            else {
                throw SendPaymentRequestError.invalidMainnetAddress
            }
            return SendPaymentRequest(
                source: .name,
                recipient: descriptor.input,
                candidateNetworkIDs:
                    descriptor.candidateNetworkIDs,
                requestedNetworkID: nil,
                requestedAsset: .unspecified,
                requestedAmount: nil,
                label: nil,
                message: nil,
                memo: nil,
                references: []
            )
        }

        return SendPaymentRequest(
            source: .bareAddress,
            recipient: address,
            candidateNetworkIDs: candidates,
            requestedNetworkID: nil,
            requestedAsset: .unspecified,
            requestedAmount: nil,
            label: nil,
            message: nil,
            memo: nil,
            references: []
        )
    }

    private static func preferredNameRequest(
        for address: String
    ) throws -> SendPaymentRequest? {
        guard address.contains(".") else { return nil }
        do {
            guard let descriptor = try SendRecipientNameParser.descriptor(
                for: address
            ) else {
                return nil
            }
            return SendPaymentRequest(
                source: .name,
                recipient: descriptor.input,
                candidateNetworkIDs: descriptor.candidateNetworkIDs,
                requestedNetworkID: nil,
                requestedAsset: .unspecified,
                requestedAmount: nil,
                label: nil,
                message: nil,
                memo: nil,
                references: []
            )
        } catch let error as SendRecipientNameError {
            let isNamedNEARAccount = address.hasSuffix(".near")
                && NEARAddress.isValid(address)
            guard isNamedNEARAccount else { throw error }
            return nil
        }
    }

    private static func parseBitcoinFamilyURI(
        _ body: String,
        chain: BitcoinFamilyChain,
        source: SendPaymentRequestSource
    ) throws -> SendPaymentRequest {
        let uri = try SendURIComponents(body: body)
        var address = uri.path
        let silentPaymentAddress = chain == .bitcoin
            ? uri.firstValue(
                named: "sp",
                includingRequiredVariant: true,
                caseInsensitive: true
            )
            : nil
        if let silentPaymentAddress {
            guard BitcoinSilentPaymentAddress.isValidMainnet(
                      silentPaymentAddress
                  ) else {
                throw SendPaymentRequestError.invalidMainnetAddress
            }
            if !address.isEmpty,
               !chain.coin.validate(address: address) {
                throw SendPaymentRequestError.invalidMainnetAddress
            }
            address = silentPaymentAddress
        }
        if chain == .bitcoinCash,
           !address.lowercased().hasPrefix("bitcoincash:") {
            address = "bitcoincash:\(address)"
        }
        guard !address.isEmpty else {
            throw SendPaymentRequestError.missingRecipient
        }
        guard SendAddressValidator.isValid(address, for: chain.networkID)
        else {
            throw SendPaymentRequestError.invalidMainnetAddress
        }

        let allowedParameterNames: Set<String> = chain == .bitcoin
            ? ["amount", "label", "message", "sp"]
            : ["amount", "label", "message"]
        try uri.rejectDuplicateParameters(
            named: allowedParameterNames,
            includingRequiredVariants: true,
            caseInsensitive: true
        )
        try uri.rejectUnknownRequiredParameters(
            allowedNames: allowedParameterNames
        )

        let amount: SendRequestedAmount?
        if let rawAmount = uri.firstValue(
            named: "amount",
            includingRequiredVariant: true,
            caseInsensitive: true
        ) {
            let parsed = try SendDecimalAmount.parseUserUnits(
                rawAmount,
                maximumFractionDigits: 8
            )
            amount = .userUnits(parsed.canonical)
        } else {
            amount = nil
        }

        return SendPaymentRequest(
            source: source,
            recipient: address,
            candidateNetworkIDs: [chain.networkID],
            requestedNetworkID: chain.networkID,
            requestedAsset: .native,
            requestedAmount: amount,
            label: try boundedMetadata(
                uri.firstValue(
                    named: "label",
                    includingRequiredVariant: true,
                    caseInsensitive: true
                )
            ),
            message: try boundedMetadata(
                uri.firstValue(
                    named: "message",
                    includingRequiredVariant: true,
                    caseInsensitive: true
                )
            ),
            memo: nil,
            references: []
        )
    }

    private static func parseEthereumURI(
        _ body: String
    ) throws -> SendPaymentRequest {
        let uri = try SendURIComponents(body: body)
        guard !uri.path.hasPrefix("//") else {
            throw SendPaymentRequestError.unsupportedFormat
        }

        let pathParts = uri.path.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let rawTarget = pathParts.first, !rawTarget.isEmpty else {
            throw SendPaymentRequestError.missingRecipient
        }

        let targetAndNetwork = rawTarget.split(
            separator: "@",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard
            let targetPart = targetAndNetwork.first,
            !targetPart.isEmpty
        else {
            throw SendPaymentRequestError.missingRecipient
        }

        var target = String(targetPart)
        if target.lowercased().hasPrefix("pay-") {
            target.removeFirst(4)
        }

        let requestedNetworkID: String?
        if targetAndNetwork.count == 2 {
            let rawChainID = String(targetAndNetwork[1])
            guard
                !rawChainID.isEmpty,
                rawChainID.allSatisfy({
                    $0 >= "0" && $0 <= "9"
                }),
                let chainID = Int(rawChainID),
                let network = SendAddressValidator.evmNetworks
                    .first(where: { $0.chainID == chainID })
            else {
                throw SendPaymentRequestError.unsupportedNetwork
            }
            requestedNetworkID = network.id
        } else {
            requestedNetworkID = nil
        }

        let candidateNetworkIDs = requestedNetworkID.map { [$0] }
            ?? SendAddressValidator.evmNetworks.map(\.id)
        let functionName = pathParts.count == 2
            ? String(pathParts[1])
            : nil

        if let functionName {
            guard functionName == "transfer" else {
                throw SendPaymentRequestError
                    .unsupportedContractFunction
            }
            guard SendAddressValidator.isValidEVMAddress(target) else {
                throw SendPaymentRequestError.invalidContractAddress
            }
            try uri.rejectDuplicateParameters(
                named: ["address", "uint256"]
            )
            try uri.rejectParameters(
                except: ["address", "uint256"]
            )
            guard
                let recipient = uri.firstValue(named: "address"),
                SendAddressValidator.isValidEVMAddress(recipient)
            else {
                throw SendPaymentRequestError.invalidMainnetAddress
            }

            let amount: SendRequestedAmount?
            if let rawAmount = uri.firstValue(named: "uint256") {
                amount = .atomicUnits(
                    try SendDecimalAmount.parseUInt256Expression(
                        rawAmount
                    )
                )
            } else {
                amount = nil
            }

            return SendPaymentRequest(
                source: .ethereumURI,
                recipient: recipient,
                candidateNetworkIDs: candidateNetworkIDs,
                requestedNetworkID: requestedNetworkID,
                requestedAsset: .contract(target),
                requestedAmount: amount,
                label: nil,
                message: nil,
                memo: nil,
                references: []
            )
        }

        guard SendAddressValidator.isValidEVMAddress(target) else {
            throw SendPaymentRequestError.invalidMainnetAddress
        }
        try uri.rejectDuplicateParameters(named: ["value"])
        try uri.rejectParameters(except: ["value"])

        let amount: SendRequestedAmount?
        if let rawAmount = uri.firstValue(named: "value") {
            amount = .atomicUnits(
                try SendDecimalAmount.parseUInt256Expression(rawAmount)
            )
        } else {
            amount = nil
        }

        return SendPaymentRequest(
            source: .ethereumURI,
            recipient: target,
            candidateNetworkIDs: candidateNetworkIDs,
            requestedNetworkID: requestedNetworkID,
            requestedAsset: .native,
            requestedAmount: amount,
            label: nil,
            message: nil,
            memo: nil,
            references: []
        )
    }

    private static func parseSolanaPayURI(
        _ body: String
    ) throws -> SendPaymentRequest {
        let uri = try SendURIComponents(body: body)
        let lowercasedPath = uri.path.lowercased()
        if lowercasedPath.hasPrefix("http://")
            || lowercasedPath.hasPrefix("https://") {
            throw SendPaymentRequestError
                .unsupportedInteractiveRequest
        }
        guard
            !uri.path.isEmpty,
            CoinType.solana.validate(address: uri.path)
        else {
            throw SendPaymentRequestError.invalidMainnetAddress
        }

        try uri.rejectDuplicateParameters(
            named: [
                "amount", "spl-token", "label", "message", "memo"
            ]
        )
        try uri.rejectParameters(
            except: [
                "amount", "spl-token", "reference", "label",
                "message", "memo"
            ]
        )

        let requestedAsset: SendRequestedAsset
        if let mint = uri.firstValue(named: "spl-token") {
            guard CoinType.solana.validate(address: mint) else {
                throw SendPaymentRequestError.invalidContractAddress
            }
            requestedAsset = .contract(mint)
        } else {
            requestedAsset = .native
        }

        let amount: SendRequestedAmount?
        if let rawAmount = uri.firstValue(named: "amount") {
            amount = .userUnits(
                try SendDecimalAmount.parseUserUnits(rawAmount)
                    .canonical
            )
        } else {
            amount = nil
        }

        let references = uri.values(named: "reference")
        guard references.count <= 10 else {
            throw SendPaymentRequestError.invalidReference
        }
        guard references.allSatisfy({
            CoinType.solana.validate(address: $0)
        }) else {
            throw SendPaymentRequestError.invalidReference
        }

        return SendPaymentRequest(
            source: .solanaPayURI,
            recipient: uri.path,
            candidateNetworkIDs: [SolanaConstants.networkID],
            requestedNetworkID: SolanaConstants.networkID,
            requestedAsset: requestedAsset,
            requestedAmount: amount,
            label: try boundedMetadata(
                uri.firstValue(named: "label")
            ),
            message: try boundedMetadata(
                uri.firstValue(named: "message")
            ),
            memo: try boundedMetadata(
                uri.firstValue(named: "memo")
            ),
            references: references
        )
    }

    private static func parseTronURI(
        _ body: String
    ) throws -> SendPaymentRequest {
        let uri = try SendURIComponents(body: body)
        guard
            !uri.path.isEmpty,
            TronValueParser.isValidMainnetAddress(uri.path)
        else {
            throw SendPaymentRequestError.invalidMainnetAddress
        }
        try uri.rejectDuplicateParameters(
            named: ["amount", "label", "message"],
            includingRequiredVariants: true,
            caseInsensitive: true
        )
        try uri.rejectUnknownRequiredParameters(
            allowedNames: ["amount", "label", "message"]
        )
        try uri.rejectParameters(
            except: ["amount", "label", "message"],
            allowsRequiredPrefix: true,
            caseInsensitive: true
        )

        let amount: SendRequestedAmount?
        if let rawAmount = uri.firstValue(
            named: "amount",
            includingRequiredVariant: true,
            caseInsensitive: true
        ) {
            amount = .userUnits(
                try SendDecimalAmount.parseUserUnits(
                    rawAmount,
                    maximumFractionDigits: 6
                )
                .canonical
            )
        } else {
            amount = nil
        }

        return SendPaymentRequest(
            source: .tronURI,
            recipient: uri.path,
            candidateNetworkIDs: [TronConstants.networkID],
            requestedNetworkID: TronConstants.networkID,
            requestedAsset: .native,
            requestedAmount: amount,
            label: try boundedMetadata(
                uri.firstValue(
                    named: "label",
                    includingRequiredVariant: true,
                    caseInsensitive: true
                )
            ),
            message: try boundedMetadata(
                uri.firstValue(
                    named: "message",
                    includingRequiredVariant: true,
                    caseInsensitive: true
                )
            ),
            memo: nil,
            references: []
        )
    }

    private static func parseTONURI(
        _ body: String
    ) throws -> SendPaymentRequest {
        let directBody: String
        if body.hasPrefix("//transfer/") {
            directBody = String(body.dropFirst("//transfer/".count))
        } else {
            directBody = body
        }
        let uri = try SendURIComponents(body: directBody)
        guard !uri.path.isEmpty,
              TONAddress.rawAddress(from: uri.path) != nil
        else {
            throw SendPaymentRequestError.invalidMainnetAddress
        }
        try uri.rejectDuplicateParameters(
            named: ["amount", "text"],
            caseInsensitive: true
        )
        try uri.rejectParameters(
            except: ["amount", "text"],
            caseInsensitive: true
        )

        let amount: SendRequestedAmount?
        if let rawAmount = uri.firstValue(
            named: "amount",
            caseInsensitive: true
        ) {
            guard rawAmount.utf8.count <= 30,
                  let canonical =
                    ExactDecimalText.canonicalUnsignedInteger(rawAmount)
            else {
                throw SendPaymentRequestError.invalidAmount
            }
            amount = .atomicUnits(canonical)
        } else {
            amount = nil
        }

        return SendPaymentRequest(
            source: .tonURI,
            recipient: uri.path,
            candidateNetworkIDs: [TONConstants.networkID],
            requestedNetworkID: TONConstants.networkID,
            requestedAsset: .native,
            requestedAmount: amount,
            label: nil,
            message: nil,
            memo: try boundedMetadata(
                uri.firstValue(
                    named: "text",
                    caseInsensitive: true
                )
            ),
            references: []
        )
    }

    private static func parseSuiURI(
        _ body: String
    ) throws -> SendPaymentRequest {
        let uri = try SendURIComponents(body: body)
        guard let address = SuiCoinType.validatedAccountAddress(uri.path)
        else {
            throw SendPaymentRequestError.invalidMainnetAddress
        }
        try uri.rejectDuplicateParameters(
            named: ["amount", "asset", "label", "message"],
            includingRequiredVariants: true,
            caseInsensitive: true
        )
        try uri.rejectUnknownRequiredParameters(
            allowedNames: ["amount", "asset", "label", "message"]
        )
        try uri.rejectParameters(
            except: ["amount", "asset", "label", "message"],
            allowsRequiredPrefix: true,
            caseInsensitive: true
        )
        let amount: SendRequestedAmount?
        if let rawAmount = uri.firstValue(
            named: "amount",
            includingRequiredVariant: true,
            caseInsensitive: true
        ) {
            amount = .userUnits(
                try SendDecimalAmount.parseUserUnits(
                    rawAmount,
                    maximumFractionDigits: SuiConstants.decimals
                ).canonical
            )
        } else {
            amount = nil
        }
        let requestedAsset: SendRequestedAsset
        if let rawAsset = uri.firstValue(
            named: "asset",
            includingRequiredVariant: true,
            caseInsensitive: true
        ) {
            guard let canonical = SuiCoinType.canonical(rawAsset) else {
                throw SendPaymentRequestError.invalidContractAddress
            }
            requestedAsset = canonical == SuiConstants.nativeCoinType
                ? .native
                : .contract(canonical)
        } else {
            requestedAsset = .native
        }
        return SendPaymentRequest(
            source: .suiURI,
            recipient: address,
            candidateNetworkIDs: [SuiConstants.networkID],
            requestedNetworkID: SuiConstants.networkID,
            requestedAsset: requestedAsset,
            requestedAmount: amount,
            label: try boundedMetadata(
                uri.firstValue(
                    named: "label",
                    includingRequiredVariant: true,
                    caseInsensitive: true
                )
            ),
            message: try boundedMetadata(
                uri.firstValue(
                    named: "message",
                    includingRequiredVariant: true,
                    caseInsensitive: true
                )
            ),
            memo: nil,
            references: []
        )
    }

    private static func boundedMetadata(
        _ value: String?
    ) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.utf8.count <= maximumMetadataBytes else {
            throw SendPaymentRequestError.payloadTooLarge
        }
        return value
    }

    private static func parseNEARURI(
        _ body: String
    ) throws -> SendPaymentRequest {
        let uri = try SendURIComponents(body: body)
        guard NEARAddress.isValid(uri.path) else {
            throw SendPaymentRequestError.invalidMainnetAddress
        }
        let supported: Set<String> = [
            "amount", "asset", "label", "message"
        ]
        try uri.rejectDuplicateParameters(
            named: supported,
            includingRequiredVariants: true,
            caseInsensitive: true
        )
        try uri.rejectUnknownRequiredParameters(allowedNames: supported)
        try uri.rejectParameters(
            except: supported,
            allowsRequiredPrefix: true,
            caseInsensitive: true
        )
        let amount: SendRequestedAmount?
        if let rawAmount = uri.firstValue(
            named: "amount",
            includingRequiredVariant: true,
            caseInsensitive: true
        ) {
            amount = .userUnits(
                try SendDecimalAmount.parseUserUnits(
                    rawAmount,
                    maximumFractionDigits: NEARConstants.decimals
                ).canonical
            )
        } else {
            amount = nil
        }
        let requestedAsset: SendRequestedAsset
        if let rawAsset = uri.firstValue(
            named: "asset",
            includingRequiredVariant: true,
            caseInsensitive: true
        ) {
            guard NEARAddress.isValid(rawAsset) else {
                throw SendPaymentRequestError.invalidContractAddress
            }
            requestedAsset = .contract(rawAsset)
        } else {
            requestedAsset = .native
        }
        return SendPaymentRequest(
            source: .nearURI,
            recipient: uri.path,
            candidateNetworkIDs: [NEARConstants.networkID],
            requestedNetworkID: NEARConstants.networkID,
            requestedAsset: requestedAsset,
            requestedAmount: amount,
            label: try boundedMetadata(
                uri.firstValue(
                    named: "label",
                    includingRequiredVariant: true,
                    caseInsensitive: true
                )
            ),
            message: try boundedMetadata(
                uri.firstValue(
                    named: "message",
                    includingRequiredVariant: true,
                    caseInsensitive: true
                )
            ),
            memo: nil,
            references: []
        )
    }

    private static func parseXRPURI(
        _ body: String
    ) throws -> SendPaymentRequest {
        let uri = try SendURIComponents(body: body)
        guard let address = XRPAddress.validated(uri.path) else {
            throw SendPaymentRequestError.invalidMainnetAddress
        }
        let supported: Set<String> = [
            "amount", "dt", "destination_tag", "label", "message"
        ]
        try uri.rejectDuplicateParameters(
            named: supported,
            includingRequiredVariants: true,
            caseInsensitive: true
        )
        try uri.rejectUnknownRequiredParameters(
            allowedNames: supported
        )
        try uri.rejectParameters(
            except: supported,
            allowsRequiredPrefix: true,
            caseInsensitive: true
        )

        let shortTag = uri.firstValue(
            named: "dt",
            includingRequiredVariant: true,
            caseInsensitive: true
        )
        let longTag = uri.firstValue(
            named: "destination_tag",
            includingRequiredVariant: true,
            caseInsensitive: true
        )
        guard shortTag == nil || longTag == nil else {
            throw SendPaymentRequestError.duplicateParameter
        }
        let tag = XRPDestinationTag.normalized(shortTag ?? longTag)
        _ = try XRPDestinationTag.parsed(tag)

        let amount: SendRequestedAmount?
        if let rawAmount = uri.firstValue(
            named: "amount",
            includingRequiredVariant: true,
            caseInsensitive: true
        ) {
            amount = .userUnits(
                try SendDecimalAmount.parseUserUnits(
                    rawAmount,
                    maximumFractionDigits: XRPConstants.decimals
                ).canonical
            )
        } else {
            amount = nil
        }
        return SendPaymentRequest(
            source: .xrpURI,
            recipient: address,
            candidateNetworkIDs: [XRPConstants.networkID],
            requestedNetworkID: XRPConstants.networkID,
            requestedAsset: .native,
            requestedAmount: amount,
            label: try boundedMetadata(
                uri.firstValue(
                    named: "label",
                    includingRequiredVariant: true,
                    caseInsensitive: true
                )
            ),
            message: try boundedMetadata(
                uri.firstValue(
                    named: "message",
                    includingRequiredVariant: true,
                    caseInsensitive: true
                )
            ),
            memo: tag,
            references: []
        )
    }

    private static func parseStellarURI(
        _ body: String
    ) throws -> SendPaymentRequest {
        let uri = try SendURIComponents(body: body)
        guard uri.path.caseInsensitiveCompare("pay") == .orderedSame else {
            throw SendPaymentRequestError.unsupportedFormat
        }
        let supported: Set<String> = [
            "destination", "amount", "asset_code", "asset_issuer",
            "memo", "memo_type"
        ]
        try uri.rejectDuplicateParameters(
            named: supported,
            caseInsensitive: true
        )
        try uri.rejectParameters(
            except: supported,
            caseInsensitive: true
        )
        guard let rawDestination = uri.firstValue(
            named: "destination",
            caseInsensitive: true
        ), let destination = StellarAddress.validated(rawDestination) else {
            throw SendPaymentRequestError.invalidMainnetAddress
        }

        let rawCode = uri.firstValue(
            named: "asset_code",
            caseInsensitive: true
        )
        let rawIssuer = uri.firstValue(
            named: "asset_issuer",
            caseInsensitive: true
        )
        let requestedAsset: SendRequestedAsset
        switch (rawCode, rawIssuer) {
        case (nil, nil):
            requestedAsset = .native
        case let (code?, issuer?):
            guard let identity = StellarAssetIdentity.validated(
                code: code,
                issuer: issuer
            ) else {
                throw SendPaymentRequestError.invalidContractAddress
            }
            requestedAsset = .contract(identity.contractAddress)
        default:
            throw SendPaymentRequestError.invalidContractAddress
        }

        let amount = try uri.firstValue(
            named: "amount",
            caseInsensitive: true
        ).map {
            SendRequestedAmount.userUnits(
                try SendDecimalAmount.parseUserUnits(
                    $0,
                    maximumFractionDigits: StellarConstants.decimals
                ).canonical
            )
        }
        let rawMemo = uri.firstValue(
            named: "memo",
            caseInsensitive: true
        )
        let memoType = uri.firstValue(
            named: "memo_type",
            caseInsensitive: true
        )
        if let memoType,
           memoType.caseInsensitiveCompare("MEMO_TEXT") != .orderedSame {
            throw SendPaymentRequestError.unsupportedParameter
        }
        let memo = StellarMemoTextValidator.normalized(rawMemo)
        if memo != nil, StellarMemoTextValidator.validated(memo) == nil {
            throw SendPaymentRequestError.unsupportedFormat
        }

        return SendPaymentRequest(
            source: .stellarURI,
            recipient: destination,
            candidateNetworkIDs: [StellarConstants.networkID],
            requestedNetworkID: StellarConstants.networkID,
            requestedAsset: requestedAsset,
            requestedAmount: amount,
            label: nil,
            message: nil,
            memo: memo,
            references: []
        )
    }
}
