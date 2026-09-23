import Foundation

actor TONAPIClient {
    static let shared = TONAPIClient()

    private let injectedTransport: TONAPITransport?

    init(transport: TONAPITransport? = nil) {
        injectedTransport = transport
    }

    private func transport() throws -> TONAPITransport {
        if let injectedTransport {
            return injectedTransport
        }
        guard let transport = TONAPITransport.shared else {
            throw TONProviderError.missingConfiguration
        }
        return transport
    }

    func loadSnapshot(
        material: TONAccountMaterial,
        onBalances:
            (@Sendable (TONWalletSnapshot) async throws -> Void)? = nil
    ) async throws -> TONWalletSnapshot {
        let transport = try transport()
        async let account: TONAPIAccount = transport.request(
            path: "account",
            body: ["address": .string(material.address)]
        )
        async let jettons = optionalJettons(
            address: material.address,
            transport: transport
        )
        async let rates = optionalRates(transport: transport)
        async let loadedEvents = events(
            address: material.address,
            transport: transport
        )

        let loadedAccount = try await account
        var latestBalanceSnapshot = try balanceSnapshot(
            material: material,
            account: loadedAccount,
            jettons: TONAPIJettonBalances(balances: []),
            rates: TONAPIRates(rates: [:]),
            jettonsAreAuthoritative: false,
            providerFailureCodes: []
        )
        if let onBalances {
            try await onBalances(latestBalanceSnapshot)
        }
        try Task.checkCancellation()

        let loadedJettons = try await jettons
        latestBalanceSnapshot = try balanceSnapshot(
            material: material,
            account: loadedAccount,
            jettons: loadedJettons.value,
            rates: TONAPIRates(rates: [:]),
            jettonsAreAuthoritative: loadedJettons.isComplete,
            providerFailureCodes: loadedJettons.failureCodes
        )
        if let onBalances {
            try await onBalances(latestBalanceSnapshot)
        }
        try Task.checkCancellation()

        let loadedRates = try await rates
        latestBalanceSnapshot = try balanceSnapshot(
            material: material,
            account: loadedAccount,
            jettons: loadedJettons.value,
            rates: loadedRates.value,
            jettonsAreAuthoritative: loadedJettons.isComplete,
            providerFailureCodes:
                loadedJettons.failureCodes + loadedRates.failureCodes
        )
        if let onBalances {
            try await onBalances(latestBalanceSnapshot)
        }
        try Task.checkCancellation()

        let resolvedEvents = try await loadedEvents
        return TONWalletSnapshot(
            material: material,
            nativeAmountText: latestBalanceSnapshot.nativeAmountText,
            nativeAtomicAmount: latestBalanceSnapshot.nativeAtomicAmount,
            nativeUSDPriceText: latestBalanceSnapshot.nativeUSDPriceText,
            tokens: latestBalanceSnapshot.tokens,
            history: try history(
                resolvedEvents.events,
                owner: material.rawAddress
            ),
            jettonsAreAuthoritative:
                latestBalanceSnapshot.jettonsAreAuthoritative,
            eventsAreAuthoritative: resolvedEvents.isComplete,
            providerFailureCodes: Array(
                Set(
                    latestBalanceSnapshot.providerFailureCodes
                        + resolvedEvents.failureCodes
                )
            ).sorted()
        )
    }

    private func balanceSnapshot(
        material: TONAccountMaterial,
        account: TONAPIAccount,
        jettons: TONAPIJettonBalances,
        rates: TONAPIRates,
        jettonsAreAuthoritative: Bool,
        providerFailureCodes: [String]
    ) throws -> TONWalletSnapshot {
        guard TONAddress.matches(
            account.address,
            material.rawAddress
        )
        else {
            throw TONProviderError.invalidResponse("account_mismatch")
        }
        guard account.isScam != true else {
            throw TONProviderError.providerRejected("account_scam")
        }
        let nativeAtomic = try exactUnsigned(account.balance.text)
        let nativeAmount = try userUnits(
            atomic: nativeAtomic,
            decimals: TONConstants.decimals
        )
        let tokens = try jettons.balances.compactMap {
            balance -> TONTokenBalance? in
            guard
                let walletAddress = TONAddress.rawAddress(
                    from: balance.walletAddress.address
                )
            else {
                throw TONProviderError.invalidResponse("jetton_address")
            }
            guard balance.walletAddress.isScam != true,
                  let definition = try tokenDefinition(
                    for: balance.jetton
                  ) else {
                return nil
            }
            let atomic = try exactUnsigned(balance.balance)
            return TONTokenBalance(
                definition: definition,
                walletAddress: walletAddress,
                amountText: try userUnits(
                    atomic: atomic,
                    decimals: definition.decimals
                ),
                atomicAmount: atomic,
                usdPriceText: balance.price?.prices["USD"]?.text
            )
        }
        return TONWalletSnapshot(
            material: material,
            nativeAmountText: nativeAmount,
            nativeAtomicAmount: nativeAtomic,
            nativeUSDPriceText: rates.rates[
                TONConstants.providerRateSymbol
            ]?
                .prices["USD"]?.text,
            tokens: tokens.sorted {
                $0.definition.rank < $1.definition.rank
            },
            history: [],
            jettonsAreAuthoritative: jettonsAreAuthoritative,
            eventsAreAuthoritative: false,
            providerFailureCodes: Array(
                Set(providerFailureCodes)
            ).sorted()
        )
    }

    private func optionalJettons(
        address: String,
        transport: TONAPITransport
    ) async throws -> TONOptionalComponent<TONAPIJettonBalances> {
        do {
            let value: TONAPIJettonBalances = try await transport.request(
                path: "jettons",
                body: [
                    "address": .string(address),
                    "limit": .integer(1_000),
                    "offset": .integer(0)
                ]
            )
            return TONOptionalComponent(
                value: value,
                isComplete: true,
                failureCodes: []
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return TONOptionalComponent(
                value: TONAPIJettonBalances(balances: []),
                isComplete: false,
                failureCodes: [providerFailureCode(error)]
            )
        }
    }

    private func optionalRates(
        transport: TONAPITransport
    ) async throws -> TONOptionalComponent<TONAPIRates> {
        do {
            let value: TONAPIRates = try await transport.request(
                path: "rates",
                body: [:]
            )
            return TONOptionalComponent(
                value: value,
                isComplete: true,
                failureCodes: []
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return TONOptionalComponent(
                value: TONAPIRates(rates: [:]),
                isComplete: false,
                failureCodes: [providerFailureCode(error)]
            )
        }
    }

    func seqno(address: String) async throws -> Int {
        let value: TONAPISeqno = try await transport().request(
            path: "seqno",
            body: ["address": .string(address)]
        )
        return value.seqno
    }

    func broadcast(
        boc: String,
        expectedHash: String
    ) async throws {
        try await transport().broadcast(
            boc: boc,
            expectedHash: expectedHash
        )
    }

    func verifiedJettonWalletAddress(
        masterAddress: String,
        ownerAddress: String
    ) async throws -> String {
        try await transport().verifiedJettonWalletAddress(
            masterAddress: masterAddress,
            ownerAddress: ownerAddress
        )
    }

    func account(address: String) async throws -> TONAPIAccount {
        guard TONAddress.rawAddress(from: address) != nil else {
            throw TONProviderError.providerRejected("invalid_address")
        }
        return try await transport().request(
            path: "account",
            body: ["address": .string(address)]
        )
    }

    func jettonBalances(
        address: String
    ) async throws -> TONAPIJettonBalances {
        guard TONAddress.rawAddress(from: address) != nil else {
            throw TONProviderError.providerRejected("invalid_address")
        }
        return try await transport().request(
            path: "jettons",
            body: [
                "address": .string(address),
                "limit": .integer(1_000),
                "offset": .integer(0)
            ]
        )
    }

    private func events(
        address: String,
        transport: TONAPITransport
    ) async throws -> TONLoadedEvents {
        do {
            let firstPage: TONAPIEvents = try await transport.request(
                path: "events",
                body: [
                    "address": .string(address),
                    "limit": .integer(100)
                ]
            )
            return try await events(
                address: address,
                initialPage: firstPage,
                initialPageComplete: true,
                transport: transport
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return TONLoadedEvents(
                events: [],
                isComplete: false,
                failureCodes: [providerFailureCode(error)]
            )
        }
    }

    private func events(
        address: String,
        initialPage: TONAPIEvents,
        initialPageComplete: Bool,
        transport: TONAPITransport
    ) async throws -> TONLoadedEvents
    {
        guard TONAddress.rawAddress(from: address) != nil else {
            return TONLoadedEvents(
                events: [],
                isComplete: false,
                failureCodes: ["ton_provider_rejected_invalid_address"]
            )
        }
        guard initialPageComplete else {
            return TONLoadedEvents(
                events: initialPage.events,
                isComplete: false,
                failureCodes: []
            )
        }
        let pageLimit = 100
        let maximumPages = 10
        var page = initialPage
        var seenCursors: Set<String> = []
        var seenEventIDs: Set<String> = []
        var result: [TONAPIEvents.Event] = []

        for pageIndex in 0..<maximumPages {
            for event in page.events
            where seenEventIDs.insert(event.eventID).inserted {
                result.append(event)
            }
            guard page.events.count == pageLimit,
                  let next = page.nextFrom?.text,
                  ExactDecimalText.canonicalUnsignedInteger(next) == next,
                  seenCursors.insert(next).inserted
            else {
                break
            }
            guard pageIndex + 1 < maximumPages else { break }
            do {
                page = try await transport.request(
                    path: "events",
                    body: [
                        "address": .string(address),
                        "limit": .integer(pageLimit),
                        "beforeLt": .string(next)
                    ]
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return TONLoadedEvents(
                    events: result,
                    isComplete: false,
                    failureCodes: [providerFailureCode(error)]
                )
            }
        }
        return TONLoadedEvents(
            events: result,
            isComplete: true,
            failureCodes: []
        )
    }

    private func history(
        _ events: [TONAPIEvents.Event],
        owner: String
    ) throws -> [TONHistoryItem] {
        var result: [TONHistoryItem] = []
        for event in events where
            event.isScam != true
                && event.inProgress != true
                && event.timestamp > 0 {
            for (index, action) in event.actions.enumerated() {
                if let transfer = action.tonTransfer {
                    guard
                        let sender = TONAddress.rawAddress(
                            from: transfer.sender.address
                        ),
                        let recipient = TONAddress.rawAddress(
                            from: transfer.recipient.address
                        )
                    else {
                        throw TONProviderError.invalidResponse(
                            "history_address"
                        )
                    }
                    let atomic = try exactUnsigned(transfer.amount.text)
                    result.append(
                        TONHistoryItem(
                            id: "\(event.eventID):\(index)",
                            transactionHash: event.eventID,
                            timestamp: event.timestamp,
                            failed: action.status != "ok",
                            from: sender,
                            to: recipient,
                            assetAddress: nil,
                            assetName: WalletLocalization.string(
                                TONConstants.nativeAssetNameKey
                            ),
                            assetSymbol: TONConstants.nativeSymbol,
                            decimals: TONConstants.decimals,
                            amountText: try userUnits(
                                atomic: atomic,
                                decimals: TONConstants.decimals
                            ),
                            atomicAmount: atomic
                        )
                    )
                } else if let transfer = action.jettonTransfer {
                    guard let definition = try tokenDefinition(
                        for: transfer.jetton
                    ) else {
                        continue
                    }
                    let sender = try optionalAddress(transfer.sender)
                    let recipient = try optionalAddress(transfer.recipient)
                    guard sender != nil || recipient != nil else {
                        continue
                    }
                    let atomic = try exactUnsigned(transfer.amount)
                    result.append(
                        TONHistoryItem(
                            id: "\(event.eventID):\(index)",
                            transactionHash: event.eventID,
                            timestamp: event.timestamp,
                            failed: action.status != "ok",
                            from: sender,
                            to: recipient,
                            assetAddress: definition.address,
                            assetName: definition.name,
                            assetSymbol: definition.symbol,
                            decimals: definition.decimals,
                            amountText: try userUnits(
                                atomic: atomic,
                                decimals: definition.decimals
                            ),
                            atomicAmount: atomic
                        )
                    )
                }
            }
        }
        return result.filter { $0.from == owner || $0.to == owner }
    }

    private func tokenDefinition(
        for jetton: TONAPIJettonBalances.Jetton
    ) throws -> TONTokenDefinition? {
        guard let address = TONAddress.rawAddress(from: jetton.address) else {
            throw TONProviderError.invalidResponse("jetton_address")
        }
        guard jetton.verification == "whitelist",
              !TokenSafetyPolicy.isHardDenied(
                networkID: TONConstants.networkID,
                contractAddress: address
              ) else {
            return nil
        }
        if let catalog = TONTokenCatalog.byAddress[address] {
            guard catalog.decimals == jetton.decimals else {
                throw TONProviderError.invalidResponse("jetton_decimals")
            }
            return catalog
        }
        guard (0...255).contains(jetton.decimals),
              AssetCatalogEntryValidation.isValidRemoteText(
                jetton.name,
                maximumLength: 160
              ),
              AssetCatalogEntryValidation.isValidRemoteText(
                jetton.symbol,
                maximumLength: 48
              ),
              !jetton.symbol.contains(where: { $0.isWhitespace })
        else {
            throw TONProviderError.invalidResponse("jetton_metadata")
        }
        return TONTokenDefinition(
            address: address,
            name: jetton.name,
            symbol: jetton.symbol,
            decimals: jetton.decimals,
            rank: 10_000
        )
    }

    private func optionalAddress(
        _ value: TONAPIAddress?
    ) throws -> String? {
        guard let value else { return nil }
        guard let normalized = TONAddress.rawAddress(from: value.address)
        else {
            throw TONProviderError.invalidResponse("history_address")
        }
        return normalized
    }

    private func exactUnsigned(_ value: String) throws -> String {
        guard let canonical =
                ExactDecimalText.canonicalUnsignedInteger(value)
        else {
            throw TONProviderError.invalidResponse("quantity")
        }
        return canonical
    }

    private func userUnits(
        atomic: String,
        decimals: Int
    ) throws -> String {
        try TronValueParser.userUnits(
            atomicDecimalText: atomic,
            decimals: decimals
        )
    }

    private func providerFailureCode(_ error: Error) -> String {
        if let error = error as? TONProviderError {
            return error.diagnosticDescription
        }
        return "ton_provider_read_failed"
    }
}

private struct TONLoadedEvents: Sendable {
    let events: [TONAPIEvents.Event]
    let isComplete: Bool
    let failureCodes: [String]
}
