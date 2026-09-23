import Foundation
import Observation
import WalletCore

enum SendAddressValidator {
    private static let independentNetworkIDs: Set<String> = [
        TronConstants.networkID,
        SolanaConstants.networkID,
        TONConstants.networkID,
        SuiConstants.networkID,
        AptosConstants.networkID,
        NEARConstants.networkID,
        XRPConstants.networkID,
        StellarConstants.networkID,
        BitcoinFamilyChain.bitcoin.networkID,
        BitcoinFamilyChain.bitcoinCash.networkID,
        BitcoinFamilyChain.litecoin.networkID,
        BitcoinFamilyChain.dogecoin.networkID
    ]

    static let evmNetworks = ReceiveNetworkCatalog.all.filter {
        !independentNetworkIDs.contains($0.id)
    }

    static func candidateNetworkIDs(
        for address: String
    ) -> [String] {
        let address = address.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !address.isEmpty else { return [] }

        // A canonical NEAR implicit account is exactly 32 lowercase
        // hexadecimal bytes without a prefix. Aptos and Sui accept the same
        // bytes after permissive normalization, but their canonical external
        // account form carries `0x`. Preserve the prefix distinction during
        // bare-address inference so a NEAR account is not mislabeled as both
        // Move networks. Explicit `aptos:` and `sui:` requests remain the
        // authoritative way to distinguish their shared `0x` address shape.
        if isCanonicalNEARImplicitAddress(address) {
            return [NEARConstants.networkID]
        }
        var candidates: [String] = []

        if BitcoinSilentPaymentAddress.isValidMainnet(address) {
            candidates.append(BitcoinFamilyChain.bitcoin.networkID)
        }
        if isValidEVMAddress(address) {
            candidates.append(contentsOf: evmNetworks.map(\.id))
        }
        if TronValueParser.isValidMainnetAddress(address) {
            candidates.append(TronConstants.networkID)
        }
        if TONAddress.rawAddress(from: address) != nil {
            candidates.append(TONConstants.networkID)
        }
        if CoinType.solana.validate(address: address) {
            candidates.append(SolanaConstants.networkID)
        }
        if SuiCoinType.validatedAccountAddress(address) != nil {
            candidates.append(SuiConstants.networkID)
        }
        if AptosAddress.canonical(address) != nil {
            candidates.append(AptosConstants.networkID)
        }
        if XRPAddress.validated(address) != nil {
            candidates.append(XRPConstants.networkID)
        }
        if StellarAddress.validated(address) != nil {
            candidates.append(StellarConstants.networkID)
        }
        for chain in BitcoinFamilyChain.allCases
        where chain.coin.validate(address: address) {
            candidates.append(chain.networkID)
        }

        // NEAR named accounts have no checksum and intentionally accept a
        // broad lowercase ASCII grammar. That grammar overlaps checksummed
        // formats such as Bitcoin Bech32 and Bitcoin Cash cashaddr. Prefer an
        // exact structural address match; a bare value is considered NEAR
        // only when no other supported address format validates it.
        if candidates.isEmpty,
           !resemblesSelfDescribingAddress(address),
           NEARAddress.isValid(address) {
            candidates.append(NEARConstants.networkID)
        }

        return AssetNetworkSelectorOption.allSupported
            .map(\.id)
            .filter(Set(candidates).contains)
    }

    static func isValid(
        _ address: String,
        for networkID: String
    ) -> Bool {
        let address = address.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !address.isEmpty else { return false }
        if evmNetworks.contains(where: { $0.id == networkID }) {
            return isValidEVMAddress(address)
        }
        if networkID == TronConstants.networkID {
            return TronValueParser.isValidMainnetAddress(address)
        }
        if networkID == SolanaConstants.networkID {
            return CoinType.solana.validate(address: address)
        }
        if networkID == TONConstants.networkID {
            return TONAddress.rawAddress(from: address) != nil
        }
        if networkID == SuiConstants.networkID {
            return SuiCoinType.validatedAccountAddress(address) != nil
        }
        if networkID == AptosConstants.networkID {
            return AptosAddress.canonical(address) != nil
        }
        if networkID == NEARConstants.networkID {
            return NEARAddress.isValid(address)
        }
        if networkID == XRPConstants.networkID {
            return XRPAddress.validated(address) != nil
        }
        if networkID == StellarConstants.networkID {
            return StellarAddress.validated(address) != nil
        }
        guard let chain = BitcoinFamilyChain.allCases.first(where: {
            $0.networkID == networkID
        }) else {
            return false
        }
        if chain == .bitcoin,
           BitcoinSilentPaymentAddress.isValidMainnet(address) {
            return true
        }
        return chain.coin.validate(address: address)
    }

    static func isValidEVMAddress(_ address: String) -> Bool {
        let address = address.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            CoinType.ethereum.validate(address: address),
            address.count == 42,
            address.lowercased()
                != "0x0000000000000000000000000000000000000000"
        else {
            return false
        }
        return true
    }

    private static func resemblesSelfDescribingAddress(
        _ address: String
    ) -> Bool {
        let lowercased = address.lowercased()
        return [
            "0x",
            "bc1",
            "tb1",
            "bcrt1",
            "sp1",
            "ltc1",
            "tltc1"
        ].contains(where: lowercased.hasPrefix)
    }

    private static func isCanonicalNEARImplicitAddress(
        _ address: String
    ) -> Bool {
        address.utf8.count == 64
            && address.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
            && NEARAddress.isValid(address)
    }
}

enum SendRecipientRequirementNetworkRule: Hashable, Sendable {
    case noActivationMinimum
    case stellarReserve
    case xrpReserve
    case solanaRent
    case nearExistence
    case unsupported

    static func rule(for networkID: String) -> Self {
        guard let blockchain = AssetNetworkSelectorOption.blockchain(
            for: networkID
        ) else { return .unsupported }
        return switch blockchain {
        case .stellar:
            .stellarReserve
        case .xrp:
            .xrpReserve
        case .solana:
            .solanaRent
        case .near:
            .nearExistence
        case .tron, .aptos, .sui, .ton, .bitcoin, .bitcoincash, .litecoin,
             .dogecoin, .ethereum, .smartchain, .polygon, .arbitrum,
             .avalanchec, .optimism, .base, .xdai, .scroll, .linea,
             .taiko, .telos, .xlayer, .arc:
            .noActivationMinimum
        }
    }

    static func requiresLiveLookup(for asset: SendAssetChoice) -> Bool {
        switch rule(for: asset.networkID) {
        case .stellarReserve, .xrpReserve, .nearExistence:
            true
        case .solanaRent:
            asset.isNative
        case .noActivationMinimum, .unsupported:
            false
        }
    }

    static func requiresLiveLookup(
        for asset: SendAssetChoice,
        recipient: String
    ) -> Bool {
        guard requiresLiveLookup(for: asset) else { return false }
        let recipient = recipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard rule(for: asset.networkID) == .nearExistence,
              asset.isNative,
              let kind = NEARAddress.kind(recipient)
        else { return true }
        return kind == .named
    }
}

struct SendRecipientMinimum: Hashable, Sendable {
    enum Reason: Hashable, Sendable {
        case stellarAccountReserve
        case xrpAccountReserve
        case solanaRent
    }

    let amountAtomic: String
    let decimals: Int
    let symbol: String
    let reason: Reason

    var displayAmount: String {
        SendDecimalAmount.userUnits(
            fromAtomicUnits: amountAtomic,
            decimals: decimals
        )
    }

    var localizedMessage: String {
        let key = switch reason {
        case .stellarAccountReserve:
            "send.recipient.requirement.stellar_minimum"
        case .xrpAccountReserve:
            "send.recipient.requirement.xrp_minimum"
        case .solanaRent:
            "send.recipient.requirement.solana_minimum"
        }
        return EnglishNumbers.localized(key, displayAmount, symbol)
    }

    func isSatisfied(
        by assetAmount: String?,
        assetDecimals: Int
    ) -> Bool {
        guard let assetAmount,
              let atomic = try? SendAtomicAmount.fromUserUnits(
                  assetAmount,
                  decimals: assetDecimals
              )
        else { return false }
        return SendAtomicAmount.compare(atomic, amountAtomic)
            != .orderedAscending
    }
}

struct SendRecipientRequirement: Hashable, Sendable {
    enum Blocker: Hashable, Sendable {
        case stellarTokenAccountInactive(SendRecipientMinimum)
        case xrpTokenAccountInactive(SendRecipientMinimum)
        case nearNamedAccountMissing
        case nearTokenAccountMissing

        var localizedMessage: String {
            switch self {
            case let .stellarTokenAccountInactive(minimum):
                EnglishNumbers.localized(
                    "send.recipient.requirement.stellar_token_inactive",
                    minimum.displayAmount,
                    minimum.symbol
                )
            case let .xrpTokenAccountInactive(minimum):
                EnglishNumbers.localized(
                    "send.recipient.requirement.xrp_token_inactive",
                    minimum.displayAmount,
                    minimum.symbol
                )
            case .nearNamedAccountMissing:
                WalletLocalization.string(
                    "send.submit.error.near_named_recipient_missing"
                )
            case .nearTokenAccountMissing:
                WalletLocalization.string(
                    "send.submit.error.near_token_recipient_missing"
                )
            }
        }
    }

    struct Presentation: Hashable, Sendable {
        let message: String
        let isBlocking: Bool
    }

    static let none = SendRecipientRequirement(
        minimum: nil,
        blocker: nil
    )

    let minimum: SendRecipientMinimum?
    let blocker: Blocker?

    func permits(
        assetAmount: String?,
        assetDecimals: Int
    ) -> Bool {
        guard blocker == nil else { return false }
        return minimum?.isSatisfied(
            by: assetAmount,
            assetDecimals: assetDecimals
        ) ?? true
    }

    func presentation(
        assetAmount: String?,
        assetDecimals: Int
    ) -> Presentation? {
        if let blocker {
            return Presentation(
                message: blocker.localizedMessage,
                isBlocking: true
            )
        }
        // Empty, zero, or invalid input belongs to amount validation. A
        // recipient funding notice is useful only for a positive, valid
        // amount below the live reserve/rent requirement.
        guard let minimum,
              let assetAmount,
              let atomic = try? SendAtomicAmount.fromUserUnits(
                  assetAmount,
                  decimals: assetDecimals
              ),
              SendAtomicAmount.compare(atomic, minimum.amountAtomic)
                == .orderedAscending
        else { return nil }
        return Presentation(
            message: minimum.localizedMessage,
            isBlocking: true
        )
    }
}

struct SendRecipientRequirementFailure: Error, Hashable, Sendable {
    let networkName: String
    let diagnosticCode: String
    let providerMessage: String

    init(
        networkName: String,
        diagnosticCode: String,
        providerMessage: String
    ) {
        self.networkName = networkName
        self.diagnosticCode = SendTransactionSubmissionError
            .sanitizedMessage(diagnosticCode)
        self.providerMessage = SendTransactionSubmissionError
            .sanitizedMessage(providerMessage)
    }

    var localizedMessage: String {
        EnglishNumbers.localized(
            "send.recipient.requirement.failed",
            networkName,
            diagnosticCode,
            providerMessage
        )
    }
}

struct SendRecipientRequirementInput: Hashable, Sendable {
    let assetID: String
    let sourceRecipient: String
    let checkedRecipient: String

    init?(
        asset: SendAssetChoice,
        sourceRecipient: String,
        checkedRecipient: String
    ) {
        let source = sourceRecipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let checked = checkedRecipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !source.isEmpty,
              SendAddressValidator.isValid(checked, for: asset.networkID),
              SendRecipientRequirementNetworkRule.requiresLiveLookup(
                  for: asset,
                  recipient: checked
              )
        else { return nil }
        assetID = asset.id
        self.sourceRecipient = source
        self.checkedRecipient = checked
    }
}

struct SendRecipientRequirementChecker: Sendable {
    static let shared = SendRecipientRequirementChecker()

    private let solanaRPC: SendSolanaRPCClient

    init(
        solanaRPC: SendSolanaRPCClient = SendSolanaRPCClient()
    ) {
        self.solanaRPC = solanaRPC
    }

    func check(
        asset: SendAssetChoice,
        recipient: String
    ) async throws -> SendRecipientRequirement {
        do {
            return try await checked(asset: asset, recipient: recipient)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as SendRecipientRequirementFailure {
            throw failure
        } catch {
            throw Self.failure(
                networkName: asset.networkName,
                error: error
            )
        }
    }

    private func checked(
        asset: SendAssetChoice,
        recipient: String
    ) async throws -> SendRecipientRequirement {
        switch SendRecipientRequirementNetworkRule.rule(
            for: asset.networkID
        ) {
        case .stellarReserve:
            async let account = StellarAPIClient.shared.accountState(
                address: recipient
            )
            async let reserve = StellarAPIClient.shared.baseReserveStroops()
            let (accountState, baseReserve) = try await (account, reserve)
            return try Self.stellarRequirement(
                accountExists: accountState != nil,
                baseReserveAtomic: baseReserve,
                isNative: asset.isNative
            )
        case .xrpReserve:
            guard let destination = XRPAddress.resolvedDestination(
                address: recipient,
                explicitTag: nil
            ) else {
                throw SendTransactionSubmissionError.invalidRecipient
            }
            async let account = XRPAPIClient.shared.optionalAccountState(
                address: destination.classicAddress
            )
            async let reserve = XRPAPIClient.shared.reserveRequirements()
            let (accountState, reserveState) = try await (account, reserve)
            return Self.xrpRequirement(
                accountExists: accountState != nil,
                baseReserveDrops: reserveState.baseDrops,
                isNative: asset.isNative
            )
        case .solanaRent:
            guard asset.isNative else { return .none }
            if asset.sourceAddress == recipient { return .none }
            let account = try await solanaRPC.accountState(address: recipient)
            let rent = try await solanaRPC.minimumBalanceForRentExemption(
                dataLength: account?.dataLength ?? 0
            )
            return Self.solanaRequirement(
                currentBalance: account?.lamports,
                rentMinimum: rent
            )
        case .nearExistence:
            guard let kind = NEARAddress.kind(recipient) else {
                throw SendTransactionSubmissionError.invalidRecipient
            }
            let exists = try await NEARAPIClient.shared.accountExists(
                accountID: recipient
            )
            return Self.nearRequirement(
                accountExists: exists,
                kind: kind,
                isNative: asset.isNative
            )
        case .noActivationMinimum:
            // TRON activation is covered by the sender's reviewed fee. Any
            // positive atomic TRX amount can create the recipient account,
            // so account existence does not gate amount entry.
            return .none
        case .unsupported:
            throw Self.failure(
                networkName: asset.networkName,
                error: SendTransactionSubmissionError.unsupportedNetwork
            )
        }
    }

    static func stellarRequirement(
        accountExists: Bool,
        baseReserveAtomic: String,
        isNative: Bool
    ) throws -> SendRecipientRequirement {
        guard !accountExists else { return .none }
        let minimum = SendRecipientMinimum(
            amountAtomic: try SendAtomicAmount.multiply(
                baseReserveAtomic,
                by: 2
            ),
            decimals: StellarConstants.decimals,
            symbol: StellarConstants.nativeSymbol,
            reason: .stellarAccountReserve
        )
        return isNative
            ? SendRecipientRequirement(
                minimum: minimum,
                blocker: nil
            )
            : SendRecipientRequirement(
                minimum: nil,
                blocker: .stellarTokenAccountInactive(minimum)
            )
    }

    static func xrpRequirement(
        accountExists: Bool,
        baseReserveDrops: UInt64,
        isNative: Bool
    ) -> SendRecipientRequirement {
        guard !accountExists else { return .none }
        let minimum = SendRecipientMinimum(
            amountAtomic: String(baseReserveDrops),
            decimals: XRPConstants.decimals,
            symbol: XRPConstants.nativeSymbol,
            reason: .xrpAccountReserve
        )
        return isNative
            ? SendRecipientRequirement(
                minimum: minimum,
                blocker: nil
            )
            : SendRecipientRequirement(
                minimum: nil,
                blocker: .xrpTokenAccountInactive(minimum)
            )
    }

    static func solanaRequirement(
        currentBalance: UInt64?,
        rentMinimum: UInt64
    ) -> SendRecipientRequirement {
        let required = SendSolanaRentPolicy.requiredRecipientFunding(
            currentBalance: currentBalance,
            rentMinimum: rentMinimum
        )
        guard required > 0 else { return .none }
        return SendRecipientRequirement(
            minimum: SendRecipientMinimum(
                amountAtomic: String(required),
                decimals: SolanaConstants.decimals,
                symbol: SolanaConstants.nativeSymbol,
                reason: .solanaRent
            ),
            blocker: nil
        )
    }

    static func nearRequirement(
        accountExists: Bool,
        kind: NEARAddress.Kind,
        isNative: Bool
    ) -> SendRecipientRequirement {
        guard !accountExists else { return .none }
        if !isNative {
            return SendRecipientRequirement(
                minimum: nil,
                blocker: .nearTokenAccountMissing
            )
        }
        guard kind == .named else { return .none }
        return SendRecipientRequirement(
            minimum: nil,
            blocker: .nearNamedAccountMissing
        )
    }

    static func failure(
        networkName: String,
        error: Error
    ) -> SendRecipientRequirementFailure {
        if let failure = error as? SendRecipientRequirementFailure {
            return failure
        }
        if let error = error as? StellarProviderError {
            return SendRecipientRequirementFailure(
                networkName: networkName,
                diagnosticCode: error.diagnosticDescription,
                providerMessage: providerMessage(error)
            )
        }
        if let error = error as? XRPProviderError {
            return SendRecipientRequirementFailure(
                networkName: networkName,
                diagnosticCode: error.diagnosticDescription,
                providerMessage: providerMessage(error)
            )
        }
        if let error = error as? NEARProviderError {
            return SendRecipientRequirementFailure(
                networkName: networkName,
                diagnosticCode: error.diagnosticDescription,
                providerMessage: providerMessage(error)
            )
        }
        if let error = error as? SendTransactionSubmissionError {
            if case let .provider(_, code, message) = error {
                return SendRecipientRequirementFailure(
                    networkName: networkName,
                    diagnosticCode: code,
                    providerMessage: message
                )
            }
            return SendRecipientRequirementFailure(
                networkName: networkName,
                diagnosticCode: error.diagnosticCode,
                providerMessage: error.localizedMessage
            )
        }
        if let error = error as? ProviderReliabilityError {
            return SendRecipientRequirementFailure(
                networkName: networkName,
                diagnosticCode: error.diagnosticDescription,
                providerMessage: WalletLocalization.string(
                    "send.submit.error.provider_transport"
                )
            )
        }
        if let error = error as? URLError {
            return SendRecipientRequirementFailure(
                networkName: networkName,
                diagnosticCode: "url_error_\(error.code.rawValue)",
                providerMessage: error.localizedDescription
            )
        }
        if error is DecodingError {
            return SendRecipientRequirementFailure(
                networkName: networkName,
                diagnosticCode: SendTransactionSubmissionError
                    .sanitizedErrorType(error),
                providerMessage: WalletLocalization.string(
                    "send.submit.error.provider_invalid_response"
                )
            )
        }
        let cocoaError = error as NSError
        return SendRecipientRequirementFailure(
            networkName: networkName,
            diagnosticCode: "\(SendTransactionSubmissionError.sanitized(cocoaError.domain))_\(cocoaError.code)",
            providerMessage: WalletLocalization.string(
                "send.submit.error.provider_no_message"
            )
        )
    }

    private static func providerMessage(
        _ error: StellarProviderError
    ) -> String {
        switch error {
        case let .invalidResponse(code), let .providerRejected(code),
             let .http(_, code):
            SendTransactionSubmissionError.sanitizedMessage(code)
        case .invalidAddress:
            SendTransactionSubmissionError.invalidRecipient.localizedMessage
        case .invalidAsset:
            SendTransactionSubmissionError.unsupportedAsset.localizedMessage
        case .insufficientFunds:
            SendTransactionSubmissionError.insufficientAssetBalance
                .localizedMessage
        }
    }

    private static func providerMessage(
        _ error: XRPProviderError
    ) -> String {
        switch error {
        case let .invalidResponse(code), let .providerRejected(code),
             let .http(_, code):
            SendTransactionSubmissionError.sanitizedMessage(code)
        case let .rpc(_, message):
            SendTransactionSubmissionError.sanitizedMessage(message)
        case .invalidAddress:
            SendTransactionSubmissionError.invalidRecipient.localizedMessage
        case .insufficientFunds:
            SendTransactionSubmissionError.insufficientAssetBalance
                .localizedMessage
        case .missingConfiguration, .invalidConfiguration:
            WalletLocalization.string("send.submit.error.xrp_provider")
        }
    }

    private static func providerMessage(
        _ error: NEARProviderError
    ) -> String {
        switch error {
        case let .invalidResponse(code), let .providerRejected(code),
             let .http(_, code):
            SendTransactionSubmissionError.sanitizedMessage(code)
        case let .rpc(_, message):
            SendTransactionSubmissionError.sanitizedMessage(message)
        case .invalidAddress:
            SendTransactionSubmissionError.invalidRecipient.localizedMessage
        case .invalidContract:
            SendTransactionSubmissionError.unsupportedAsset.localizedMessage
        case .insufficientFunds:
            SendTransactionSubmissionError.insufficientAssetBalance
                .localizedMessage
        case .missingConfiguration, .invalidConfiguration:
            WalletLocalization.string("send.submit.error.near_provider")
        }
    }
}

@MainActor
@Observable
final class SendRecipientRequirementModel {
    typealias Check = @Sendable (
        SendAssetChoice,
        String
    ) async throws -> SendRecipientRequirement

    private enum Status: Hashable {
        case checking
        case ready(SendRecipientRequirement)
        case failed(SendRecipientRequirementFailure)
    }

    private struct Snapshot: Hashable {
        let input: SendRecipientRequirementInput
        let status: Status
    }

    private var snapshot: Snapshot?
    @ObservationIgnored private let check: Check
    @ObservationIgnored private var scheduledRefreshTask: Task<Void, Never>?

    init(checker: SendRecipientRequirementChecker = .shared) {
        check = { asset, recipient in
            try await checker.check(asset: asset, recipient: recipient)
        }
    }

    init(check: @escaping Check) {
        self.check = check
    }

    func reset() {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        snapshot = nil
    }

    func schedule(
        input: SendRecipientRequirementInput?,
        asset: SendAssetChoice,
        debounce: Duration = .milliseconds(300)
    ) {
        scheduledRefreshTask?.cancel()
        guard let input else {
            scheduledRefreshTask = nil
            snapshot = nil
            return
        }
        snapshot = Snapshot(input: input, status: .checking)
        scheduledRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
                try Task.checkCancellation()
            } catch {
                return
            }
            guard let self else { return }
            await self.refresh(input: input, asset: asset)
        }
    }

    func cancelScheduledRefresh() {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
    }

    func waitForScheduledRefresh() async {
        await scheduledRefreshTask?.value
    }

    @discardableResult
    func refresh(
        input: SendRecipientRequirementInput,
        asset: SendAssetChoice
    ) async -> SendRecipientRequirement? {
        snapshot = Snapshot(input: input, status: .checking)
        do {
            let result = try await check(
                asset,
                input.checkedRecipient
            )
            try Task.checkCancellation()
            guard snapshot?.input == input else { return nil }
            snapshot = Snapshot(input: input, status: .ready(result))
            return result
        } catch is CancellationError {
            return nil
        } catch let failure as SendRecipientRequirementFailure {
            guard snapshot?.input == input else { return nil }
            snapshot = Snapshot(input: input, status: .failed(failure))
            return nil
        } catch {
            let failure = SendRecipientRequirementChecker.failure(
                networkName: asset.networkName,
                error: error
            )
            guard snapshot?.input == input else { return nil }
            snapshot = Snapshot(input: input, status: .failed(failure))
            return nil
        }
    }

    func allowsReview(
        asset: SendAssetChoice,
        sourceRecipient: String,
        assetAmount: String?,
        baseFormIsValid: Bool
    ) -> Bool {
        guard baseFormIsValid else { return false }
        let source = sourceRecipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard SendRecipientRequirementNetworkRule.requiresLiveLookup(
            for: asset,
            recipient: source
        ) else { return true }
        guard let snapshot, snapshot.input.sourceRecipient == source,
              snapshot.input.assetID == asset.id
        else { return false }
        guard case let .ready(requirement) = snapshot.status else {
            return false
        }
        return requirement.permits(
            assetAmount: assetAmount,
            assetDecimals: asset.decimals
        )
    }

    func presentation(
        asset: SendAssetChoice,
        sourceRecipient: String,
        assetAmount: String?
    ) -> SendRecipientRequirement.Presentation? {
        let source = sourceRecipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let snapshot, snapshot.input.sourceRecipient == source,
              snapshot.input.assetID == asset.id
        else { return nil }
        switch snapshot.status {
        case .checking:
            return SendRecipientRequirement.Presentation(
                message: WalletLocalization.string(
                    "send.recipient.requirement.checking"
                ),
                isBlocking: false
            )
        case let .ready(requirement):
            return requirement.presentation(
                assetAmount: assetAmount,
                assetDecimals: asset.decimals
            )
        case let .failed(failure):
            return SendRecipientRequirement.Presentation(
                message: failure.localizedMessage,
                isBlocking: true
            )
        }
    }

    func canRetry(
        asset: SendAssetChoice,
        sourceRecipient: String
    ) -> Bool {
        let source = sourceRecipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let snapshot, snapshot.input.sourceRecipient == source,
              snapshot.input.assetID == asset.id,
              case .failed = snapshot.status
        else { return false }
        return true
    }

    @discardableResult
    func retry(
        asset: SendAssetChoice
    ) async -> SendRecipientRequirement? {
        guard let input = snapshot?.input,
              input.assetID == asset.id
        else { return nil }
        return await refresh(input: input, asset: asset)
    }
}
