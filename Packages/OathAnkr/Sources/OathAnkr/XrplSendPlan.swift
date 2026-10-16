import Foundation

public enum XrplSendError: Error, Equatable, Sendable {
    case recipientMinimum(UInt64)
    case configuration, malformed, wrongNetwork, wrongOwner, amount, sameRecipient, insufficientFunds, reserve, destinationTag
    case recipientUnfunded, unsupportedAccount, feeTooHigh, expired, changed, signing, busy, transport, http(Int), rpc(String)
    case simulation(String), execution(String)
    case closureUnavailable, closureTooSoon, closureObligations
}
public enum XrplSendNetwork: String, Codable, Sendable {
    case mainnet, testnet
    public var id: UInt32 { self == .mainnet ? 0 : 1 }
    public var endpoint: URL { URL(string:self == .mainnet ? "https://xrplcluster.com" : "https://s.altnet.rippletest.net:51234")! }
}

/// A locally constructed Payment, or explicitly approved AccountDelete intent.
/// AccountDelete sends the entire remaining balance; it has no Amount field.
public struct XrplSendPlan: Codable, Sendable, Equatable {
    public let network: XrplSendNetwork
    public let sender: String, recipient: String, reference: String
    public let destinationTag: UInt32?
    public let requestedAmount: String, amount: String, assetDebit: String, assetBalance: String
    public let nativeBalance: UInt64, reserve: UInt64, fee: UInt64
    /// New recipient funding from the quoted ledger, not the sender's reserve.
    /// Optional so persisted plans from older versions remain decodable.
    public let recipientReserve: UInt64?
    /// Only set after explicit account-closure consent; absent in legacy Payment plans.
    public let accountDeletionFee: UInt64?
    public var closesAccount: Bool { accountDeletionFee != nil }
    public let sequence: UInt32, firstLedger: UInt32, lastLedger: UInt32
    public let createdAt: Date
    public static let maximumFee: UInt64 = 100_000 // Never silently burn more than 0.1 XRP.
    public var adjusted: Bool { requestedAmount != amount }
    public var tokenFee: String { SuiIdentity.add(assetDebit,"-"+amount) }
    public var remaining: String { SuiIdentity.add(SuiIdentity.add(assetBalance,"-"+assetDebit), reference == "native" ? "-"+String(fee):"0") }

    public init(network: XrplSendNetwork, sender: String, recipient: String, reference: String, destinationTag: UInt32? = nil,
                requestedAmount: String, amount: String, assetDebit: String, assetBalance: String,
                nativeBalance: UInt64, reserve: UInt64, fee: UInt64, sequence: UInt32, firstLedger: UInt32,
                lastLedger: UInt32, createdAt: Date = .now, recipientReserve: UInt64? = nil, accountDeletionFee: UInt64? = nil) {
        self.network = network; self.sender = sender; self.recipient = recipient; self.reference = reference
        self.destinationTag = destinationTag; self.requestedAmount = requestedAmount; self.amount = amount
        self.assetDebit = assetDebit; self.assetBalance = assetBalance; self.nativeBalance = nativeBalance
        self.reserve = reserve; self.fee = fee; self.sequence = sequence; self.firstLedger = firstLedger
        self.lastLedger = lastLedger; self.createdAt = createdAt
        self.recipientReserve = recipientReserve
        self.accountDeletionFee = accountDeletionFee
    }
    public func validate(now: Date = .now, checkAge: Bool = true) throws {
        guard !checkAge || (-5...90).contains(now.timeIntervalSince(createdAt)) else { throw XrplSendError.expired }
        guard sender == (try XrplIdentity.address(sender)), recipient == (try XrplIdentity.address(recipient)), sender != recipient,
              reference == (try XrplIdentity.reference(reference)), sequence > 0, firstLedger > 0,
              lastLedger > firstLedger, lastLedger-firstLedger <= 30,
              fee > 0, nativeBalance <= 100_000_000_000_000_000,
              reserve <= nativeBalance, fee < nativeBalance else { throw XrplSendError.malformed }
        for value in [requestedAmount,amount,assetDebit,assetBalance] {
            guard value == (try XrplSendAmount.canonical(value)) else { throw XrplSendError.amount }
        }
        guard amount != "0", !XrplSendAmount.less(requestedAmount,amount), !XrplSendAmount.less(assetDebit,amount),
              !XrplSendAmount.less(assetBalance,assetDebit) else { throw XrplSendError.insufficientFunds }
        if let closingFee = accountDeletionFee {
            // This feature is deliberately limited to the last 1 XRP, with no
            // owned objects. Never relax ordinary Payment reserve/fee limits.
            guard reference == "native", nativeBalance == 1_000_000, reserve == nativeBalance,
                  closingFee == fee, fee <= 500_000, recipientReserve == 0,
                  UInt64(sequence) + 256 < UInt64(firstLedger),
                  assetBalance == String(nativeBalance), requestedAmount == assetBalance,
                  amount == String(nativeBalance-fee), assetDebit == amount else { throw XrplSendError.closureUnavailable }
        } else if reference == "native" {
            guard fee <= Self.maximumFee, fee <= nativeBalance-reserve, assetBalance == String(nativeBalance), assetDebit == amount,
                  let drops = UInt64(amount), drops <= nativeBalance-reserve-fee else { throw XrplSendError.reserve }
        } else if reference.contains(".") {
            guard fee <= Self.maximumFee, fee <= nativeBalance-reserve else { throw XrplSendError.reserve }
            _ = try XrplSendAmount.issuedValue(amount); _ = try XrplSendAmount.issuedValue(assetDebit)
        } else {
            guard fee <= Self.maximumFee, fee <= nativeBalance-reserve else { throw XrplSendError.reserve }
            guard let value = UInt64(assetDebit), value <= UInt64(Int64.max) else { throw XrplSendError.amount }
        }
    }
    public func transactionJSON() throws -> XrplJSON {
        try validate(checkAge:false)
        var tx: [String:XrplJSON] = ["TransactionType":.string(closesAccount ? "AccountDelete":"Payment"),"Flags":.number("2147483648"),
            "Account":.string(sender),"Destination":.string(recipient),"Amount":try XrplSendAmount.json(reference:reference,atomic:amount),
            "Fee":.string(String(fee)),"Sequence":.number(String(sequence)),"LastLedgerSequence":.number(String(lastLedger))]
        if closesAccount { tx.removeValue(forKey:"Amount") }
        if let destinationTag { tx["DestinationTag"] = .number(String(destinationTag)) }
        if reference != "native" { tx["SendMax"] = try XrplSendAmount.json(reference:reference,atomic:assetDebit) }
        return .object(tx)
    }
}

public struct XrplSignedSend: Codable, Sendable, Equatable {
    public let bytes: Data, publicKey: Data, signature: Data
    public let hash: String
    public init(bytes: Data, publicKey: Data, signature: Data, hash: String) {
        self.bytes = bytes; self.publicKey = publicKey; self.signature = signature; self.hash = hash
    }
}
public struct XrplSendReceipt: Sendable, Equatable {
    public enum Outcome: String, Sendable { case unknown, accepted, confirmed, failed, expired }
    public let hash: String, outcome: Outcome
    public let fee: UInt64?, ledger: UInt32?, code: String?
    public let deliveredAmount: String?
    public init(hash: String, outcome: Outcome, fee: UInt64? = nil, ledger: UInt32? = nil, code: String? = nil, deliveredAmount: String? = nil) {
        self.hash = hash; self.outcome = outcome; self.fee = fee; self.ledger = ledger; self.code = code; self.deliveredAmount = deliveredAmount
    }
}
