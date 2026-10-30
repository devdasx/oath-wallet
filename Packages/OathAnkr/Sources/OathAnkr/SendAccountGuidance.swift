import Foundation

/// Presentation-only recovery advice. No addresses, provider text or secrets;
/// amounts come from the same verified quote state that rejected the transfer.
public struct SendAccountGuidance: Sendable, Equatable, Identifiable {
    public enum Topic: String, Sendable {
        case xrpActivation, stellarActivation, solanaActivation
        case xrpTokenActivation, stellarTokenActivation, stellarTrustline
        case xrpReserve, stellarReserve
        case tronActivation, tronTokenActivation, tronResources, tronSenderActivation
        case nearAccount, nearTokenActivation, nearStorage, nearStorageUnsupported
        case solanaRent, solanaStorage
    }
    public enum Action: Sendable { case editAmount, editRecipient, refresh }
    public let topic: Topic
    public let action: Action
    public let minimumAtomic: UInt64?
    public let isBlocking: Bool
    public let cost: SendAccountCost?
    public var id: String { topic.rawValue }
    public init(_ topic: Topic, action: Action = .refresh, minimumAtomic: UInt64? = nil, isBlocking: Bool = true, cost: SendAccountCost? = nil) {
        self.topic = topic; self.action = action; self.minimumAtomic = minimumAtomic; self.isBlocking = isBlocking
        self.cost = cost
    }

    /// Only typed, known account requirements get this advice. Transport,
    /// malformed responses and arbitrary simulation errors keep their retry UI.
    public static func failure(_ error: Error, native: Bool, implicitNearRecipient: Bool = false) -> Self? {
        if let error = error as? XrplSendError {
            switch error {
            case .recipientMinimum(let minimum): return .init(.xrpActivation, action: .editAmount, minimumAtomic: minimum)
            case .recipientUnfunded: return .init(.xrpTokenActivation, action: .editRecipient)
            case .reserve: return .init(.xrpReserve, action: native ? .editAmount : .refresh)
            default: return nil
            }
        }
        if let error = error as? StellarSendError {
            switch error {
            case .recipientMinimum(let minimum): return .init(.stellarActivation, action: .editAmount, minimumAtomic: minimum)
            case .recipientUnfunded: return .init(.stellarTokenActivation, action: .editRecipient)
            case .trustline: return .init(.stellarTrustline, action: .editRecipient)
            case .reserve: return .init(.stellarReserve, action: native ? .editAmount : .refresh)
            default: return nil
            }
        }
        if let error = error as? TronSendError {
            switch error {
            case .activationFunds(let required): return .init(.tronActivation, action: native ? .editAmount : .refresh, minimumAtomic: required)
            case .senderInactive: return .init(.tronSenderActivation)
            default: return nil
            }
        }
        if let error = error as? NearSendError {
            switch error {
            case .recipientMissing: return .init(implicitNearRecipient ? .nearTokenActivation : .nearAccount, action: .editRecipient)
            case .storageUnsupported: return .init(.nearStorageUnsupported, action: .editRecipient)
            case .storageFunds: return .init(.nearStorage)
            default: return nil
            }
        }
        if let error = error as? SolanaSendError {
            switch error {
            case .recipientMinimum(let minimum): return .init(.solanaActivation, action: .editAmount, minimumAtomic: minimum)
            case .accountRent: return .init(.solanaRent)
            case .storageBalance: return .init(.solanaStorage, action: native ? .editAmount : .refresh)
            default: return nil
            }
        }
        return nil
    }
}

/// Only costs proved by a successful quote. The inclusion makes accounting
/// explicit: recipient funding is never added to the payment a second time.
/// Unknown legacy metadata yields no invented reserve or activation charge.
public struct SendAccountCost: Sendable, Equatable {
    public enum Kind: Sendable { case xrpReserve, stellarReserve, solanaReserve, tronCreation, solanaTokenDeposit, nearStorage }
    public enum Inclusion: Sendable { case payment, networkFee, additional }
    public let kind: Kind
    public let atomic: String
    public var inclusion: Inclusion {
        switch kind {
        case .xrpReserve, .stellarReserve, .solanaReserve: .payment
        case .tronCreation: .networkFee
        case .solanaTokenDeposit, .nearStorage: .additional
        }
    }
    public var decimals: Int {
        switch kind {
        case .xrpReserve, .tronCreation: 6
        case .stellarReserve: 7
        case .solanaReserve, .solanaTokenDeposit: 9
        case .nearStorage: 24
        }
    }
    public var symbol: String {
        switch kind {
        case .xrpReserve: "XRP"
        case .stellarReserve: "XLM"
        case .solanaReserve, .solanaTokenDeposit: "SOL"
        case .tronCreation: "TRX"
        case .nearStorage: "NEAR"
        }
    }
    public var guidance: SendAccountGuidance {
        let topic: SendAccountGuidance.Topic
        switch kind {
        case .xrpReserve: topic = .xrpActivation
        case .stellarReserve: topic = .stellarActivation
        case .solanaReserve: topic = .solanaActivation
        case .tronCreation: topic = .tronActivation
        case .solanaTokenDeposit: topic = .solanaRent
        case .nearStorage: topic = .nearStorage
        }
        return .init(topic, isBlocking: false, cost: self)
    }
}

extension XrplSendPlan {
    public var accountCost: SendAccountCost? {
        guard reference == "native", let recipientReserve, recipientReserve > 0,
              let value = UInt64(amount), recipientReserve <= value else { return nil }
        return .init(kind: .xrpReserve, atomic: String(recipientReserve))
    }
}
extension StellarSendPlan {
    public var accountCost: SendAccountCost? {
        guard kind == .createAccount, reference == "native", let recipientReserve, recipientReserve > 0,
              let value = UInt64(amount), recipientReserve <= value else { return nil }
        return .init(kind: .stellarReserve, atomic: String(recipientReserve))
    }
}
extension TronSendPlan {
    public var accountCost: SendAccountCost? {
        guard removal == nil, !isContract, recipientNeedsActivation == true,
              let accountCreationFee, accountCreationFee > 0, accountCreationFee <= fee else { return nil }
        return .init(kind: .tronCreation, atomic: String(accountCreationFee))
    }
    /// The separately displayed creation row is already part of total fee.
    public var feeExcludingAccountCreation: UInt64 { fee - (accountCost == nil ? 0 : accountCreationFee ?? 0) }
}
extension SolanaSendPlan {
    public var accountCost: SendAccountCost? {
        guard removal == nil else { return nil }
        if reference != "native", rent > 0 { return .init(kind: .solanaTokenDeposit, atomic: String(rent)) }
        guard reference == "native", let recipientReserve, recipientReserve > 0, recipientReserve <= amount else { return nil }
        return .init(kind: .solanaReserve, atomic: String(recipientReserve))
    }
}
extension NearSendPlan {
    public var accountCost: SendAccountCost? {
        guard reference != "native", storageDeposit != "0" else { return nil }
        return .init(kind: .nearStorage, atomic: storageDeposit)
    }
}
