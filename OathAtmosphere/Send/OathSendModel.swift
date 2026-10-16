import OathDiagnostics
import Foundation
import OathAnkr
import Observation
import OathDatabase
import OathBitcoin

@MainActor @Observable
final class OathSendModel {
    enum Step: Hashable { case recipient, amount, review }
    var walletID: String { didSet { if walletID != oldValue { xrplAccountClosure = nil } } }
    var holdingID: String?
    var path: [Step] = []
    var query = ""
    var address = "" { didSet { if address != oldValue { xrplAccountClosure = nil } } }
    var memo = "" { didSet { if memo != oldValue { xrplAccountClosure = nil } } }
    var stellarMemoType: StellarSendMemoType = .text
    private(set) var amount = ""
    private(set) var maximumAmount: OathSendMaximumAmount?
    private(set) var xrplAccountClosure: XrplSendPlan?
    private(set) var fiatEntry: Bool
    var replaceable = false
    var onChainMessage = ""
    private(set) var reviewOptions = BitcoinSendOptions()
    var bitcoinOptions: BitcoinSendOptions {
        .init(replaceable: replaceable, message: Data(onChainMessage.utf8))
    }
    var bitcoinOptionsValid: Bool {
        guard supportsBitcoinSend, let network = chain.flatMap({ UTXONetwork(rawValue: $0.rawValue) }) else { return true }
        // Expected form validation; do not report message contents or keystrokes.
        return (!replaceable || BitcoinSendOptions.supportsRBF(network)) &&
            onChainMessage.utf8.count <= BitcoinSendOptions.maximumMessageBytes(network)
    }
    private(set) var reviewAtomic: String?
    private(set) var reviewPrice: Decimal?
    private(set) var reviewCurrency: String?
    var recipientName: String?
    var addressError = false
    var memoError = false
    private(set) var snapshot: WalletSnapshot?
    private(set) var loading = true
    private(set) var failed = false
    private(set) var recipients: [SendRecipient] = []
    private(set) var contactsFailed = false
    private var generation = UUID()
    private var contactsGeneration = UUID()
    private var initialHoldingID: String?
    @ObservationIgnored private let preferences: UserDefaults

    init(walletID: String, holdingID: String? = nil, preferences: UserDefaults = .standard) {
        self.walletID = walletID
        self.preferences = preferences
        fiatEntry = OathSendUnitPreference.isFiat(in: preferences)
        initialHoldingID = holdingID
    }

    var holding: Holding? { snapshot?.holdings.first { $0.id == holdingID } }
    var chain: OathImportChain? { holding.flatMap { OathImportChain(rawValue: $0.networkID) } }
    var selfTransferRestriction: OathSendRecipientRules.SelfTransferRestriction? {
        guard let holding, let chain else { return nil }
        return OathSendRecipientRules.selfTransferRestriction(sender: holding.address, recipient: address,
                                                              chain: chain, reference: holding.reference)
    }
    var supportsBitcoinSend: Bool {
        (chain == .bitcoin || chain == .bitcoincash || chain == .litecoin || chain == .dogecoin) && holding?.reference == "native" && holding?.decimals == 8
    }
    var supportsSuiSend: Bool { chain == .sui }
    var supportsTonSend: Bool { chain == .ton }
    var supportsSolanaSend: Bool { chain == .solana }
    var supportsEVMSend: Bool { chain.flatMap { EVMSendNetwork(rawValue:$0.rawValue) }?.isTestnet == false }
    var supportsArcSend: Bool { chain == .arc }
    var supportsThorchainSend: Bool { chain == .thorchain }
    var supportsAptosSend: Bool { chain == .aptos }
    var supportsNearSend: Bool { chain == .near }
    var supportsTronSend: Bool { chain == .tron }
    var supportsStellarSend: Bool { chain == .stellar }
    var supportsXrplSend: Bool { chain == .xrpl }
    var canOfferXrplAccountClosure: Bool {
        supportsXrplSend && holding?.reference == "native" && holding?.amountAtomic == "1000000"
    }
    var supportsSend: Bool {
        guard let chain, OathTrackedSendChain(rawValue: chain.id) != nil else { return false }
        return supportsEVMSend || supportsArcSend || supportsBitcoinSend || supportsSuiSend || supportsXrplSend || supportsStellarSend || supportsTronSend || supportsNearSend || supportsSolanaSend || supportsAptosSend || supportsThorchainSend || supportsTonSend
    }
    var currency: String { snapshot?.currency ?? "USD" }
    var price: Decimal? {
        guard let raw = holding?.price, let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN, value > 0 else { return nil }
        return value
    }
    var canUseFiat: Bool {
        guard let holding else { return false }
        return OathSendUnitPreference.allowsFiat(price: price, decimals: holding.decimals)
    }
    var stellarMemoLabel: OathStringKey {
        switch stellarMemoType {
        case .text: .stellarMemoText
        case .id: .stellarMemoID
        case .hash: .stellarMemoHash
        case .returnHash: .stellarMemoReturn
        }
    }
    var memoKind: OathStringKey? {
        switch holding?.networkID {
        case "xrpl": .sendDestinationTag
        case "stellar", "ton", "solana", "thorchain": .sendMemo
        default: nil
        }
    }
    var holdings: [Holding] {
        // WalletSnapshot already uses the shared AssetOrdering policy. Keep
        // that order; sorting here reparses atomic balances/prices on MainActor
        // and was repeated by every lazy row's separator check while scrolling.
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return (snapshot?.holdings ?? []).filter { holding in
            guard OathImportChain(rawValue: holding.networkID) != nil else { return false }
            return words.allSatisfy { word in
                [holding.name, holding.symbol, holding.networkID, holding.reference].contains {
                    $0.localizedStandardContains(word)
                }
            }
        }
    }

    func observe(currency: String) async {
        let token = UUID(), source = walletID
        generation = token; loading = true; failed = false
        if snapshot?.wallet.id != source { snapshot = nil }
        do {
            let database = try await OathDataEnvironment.shared.database()
            for try await snapshot in database.observeWallet(walletID: source, currency: currency) {
                guard !Task.isCancelled, generation == token, walletID == source else { return }
                let old = holding
                let previousCurrency = self.snapshot?.currency
                self.snapshot = snapshot
                if let previousCurrency, previousCurrency != snapshot.currency, fiatEntry {
                    // Keep the chosen unit, but never reinterpret a value
                    // entered in another currency as the new currency.
                    amount = ""
                    maximumAmount = nil
                    if path.contains(.review) { path = [.recipient, .amount] }
                }
                loading = false; failed = false
                if let target = initialHoldingID {
                    initialHoldingID = nil
                    if let item = snapshot.holdings.first(where: { $0.id == target }) { choose(item) }
                } else if let old, holding?.address != old.address || holding?.reference != old.reference {
                    // Account/path switching invalidates the entire draft, including
                    // recipient and amount; never retarget an existing review.
                    resetDraft()
                }
                updateEntryAvailability()
            }
        } catch { OathDiagnostics.record(error);
            guard !Task.isCancelled, generation == token else { return }
            failed = true; loading = false
        }
    }

    func observeRecipients() async {
        let token = UUID(), network = holding?.networkID
        contactsGeneration = token; recipients = []; contactsFailed = false
        guard let network else { return }
        do {
            let database = try await OathDataEnvironment.shared.database()
            for try await entries in database.observeSendRecipients(networkID: network) {
                guard !Task.isCancelled, contactsGeneration == token, holding?.networkID == network else { return }
                recipients = entries
            }
        } catch { OathDiagnostics.record(error);
            if !Task.isCancelled, contactsGeneration == token { contactsFailed = true }
        }
    }

    func selectWallet(_ id: String) {
        guard id != walletID else { return }
        generation = UUID(); initialHoldingID = nil; resetDraft()
        snapshot = nil; query = ""; walletID = id
    }

    func choose(_ holding: Holding, scannedRecipient: OathScannedRecipient? = nil) {
        resetDraft(); holdingID = holding.id; path = [.recipient]
        updateEntryAvailability()
        if let scannedRecipient, let chain, !receiveScan(scannedRecipient, chain: chain) {
            // Expected stale/incompatible scan validation. No partial payload is
            // applied, and no scanned contents enter diagnostics.
            addressError = true
        }
    }

    /// Commit all supported payment fields together, after asset selection.
    /// A token/chain mismatch never partially overwrites the current draft.
    @discardableResult func receiveScan(_ result: OathScannedRecipient, chain: OathImportChain) -> Bool {
        guard let holding, chain.rawValue == holding.networkID,
              result.matchesAsset(networkID: holding.networkID, reference: holding.reference),
              let decoded = result.decoded(on: chain) else { return false }
        var scannedAmount: String?
        if let amount = result.amount {
            if result.amountIsAtomic {
                guard let units = OathSendAmount.units(amount, decimals: holding.decimals) else { return false }
                scannedAmount = units
            } else {
                guard (try? OathSendAmount.atomic(amount, decimals: holding.decimals, locale: Locale(identifier: "en_US_POSIX"))) != nil else { return false }
                scannedAmount = amount
            }
        }
        let memoType = StellarSendMemoType(rawValue: decoded.memoType ?? "text") ?? .text
        guard chain == .stellar ? (try? StellarSendMemo(type: memoType, value: decoded.memo ?? "").validate()) != nil
            : OathSendRecipientRules.validMemo(decoded.memo ?? "", networkID: chain.rawValue) else { return false }
        address = decoded.address; memo = decoded.memo ?? ""; stellarMemoType = memoType; recipientName = nil
        addressError = false; memoError = false
        if let scannedAmount { fiatEntry = false; amount = scannedAmount; maximumAmount = nil }
        return true
    }

    func setRecipient(_ entry: SendRecipient) {
        guard entry.networkID == holding?.networkID else { return }
        address = entry.address; recipientName = entry.name; memo = ""; stellarMemoType = .text
        addressError = false; memoError = false
    }

    func validateRecipient() -> Bool {
        guard let holding else { return false }
        address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        addressError = !OathContactAddressValidator.isValid(address, networkID: holding.networkID)
        // Tags are UInt32; Stellar text memos have a 28-byte UTF-8 limit.
        memoError = supportsStellarSend ? (try? StellarSendMemo(type:stellarMemoType,value:memo).validate()) == nil : !OathSendRecipientRules.validMemo(memo, networkID: holding.networkID)
        return !addressError && !memoError && selfTransferRestriction == nil
    }

    func atomic(locale: Locale) throws -> String {
        guard let holding else { throw OathSendAmount.Failure.invalid }
        let raw: String
        if let maximumAmount {
            guard maximumAmount.atomic != "0" else { throw OathSendAmount.Failure.zero }
            raw = maximumAmount.atomic
        } else if fiatEntry {
            guard let price else { throw OathSendAmount.Failure.invalid }
            let converted = try OathSendAmount.fromFiat(amount, price: price, decimals: holding.decimals, locale: locale)
            raw = supportsXrplSend && holding.reference.contains(".") ? try XrplSendAmount.roundedIssued(converted,up:false):converted
        } else {
            raw = try OathSendAmount.atomic(amount, decimals: holding.decimals, locale: locale)
            if supportsXrplSend, holding.reference.contains(".") {
                // Expected live precision validation; never log typed amounts.
                guard (try? XrplSendAmount.issuedValue(raw)) != nil else { throw OathSendAmount.Failure.precision }
            }
        }
        if supportsAptosSend {
            // Expected live form validation, including fiat and Max. Reject
            // before navigation/network work; never log the entered amount.
            guard (try? AptosSendClient.validatedAmount(raw)) != nil else { throw OathSendAmount.Failure.invalid }
        }
        return raw
    }

    func amountFailure(locale: Locale) -> OathSendAmount.Failure? {
        do { return OathSendAmount.validate(try atomic(locale: locale), balance: holding?.amountAtomic) }
        catch let error as OathSendAmount.Failure { return error } // diagnostics: expected live amount validation
        catch { OathDiagnostics.record(error); return .invalid }
    }

    func prepareReview(locale: Locale) -> Bool {
        guard !failed, !loading, bitcoinOptionsValid, validateRecipient(), amountFailure(locale: locale) == nil,
              let raw = try? atomic(locale: locale) else { return false }
        // Freeze the exact native intent at Review. A later market quote must
        // never change the quantity the user is checking in a fiat draft.
        reviewAtomic = raw; reviewPrice = price; reviewCurrency = currency
        reviewOptions = bitcoinOptions
        path.append(.review)
        return true
    }

    var reviewNeedsUpdate: Bool {
        guard let raw = reviewAtomic else { return true }
        if let closure = xrplAccountClosure, holding?.amountAtomic != String(closure.nativeBalance) { return true }
        return (supportsBitcoinSend && reviewOptions != bitcoinOptions) || failed || loading || reviewCurrency != currency || OathSendAmount.validate(raw, balance: holding?.amountAtomic) != nil
    }

    @discardableResult func useAccountClosure(_ plan: XrplSendPlan) -> Bool {
        guard canOfferXrplAccountClosure, holding?.address == plan.sender, address == plan.recipient, UInt32(memo) == plan.destinationTag,
              plan.closesAccount, (try? plan.validate()) != nil,
              let maximum = OathSendMaximumAmount(balance:plan.amount,decimals:6) else { return false }
        xrplAccountClosure = plan; maximumAmount = maximum; amount = maximum.units; fiatEntry = false
        return true
    }

    func useBalance() {
        xrplAccountClosure = nil
        guard let holding,
              let maximum = OathSendMaximumAmount(balance: holding.amountAtomic, decimals: holding.decimals) else { return }
        maximumAmount = maximum
        amount = maximum.units
        // Max is a temporary native display, not a new saved unit preference.
        fiatEntry = false
    }

    func switchUnit(locale: Locale) {
        guard let holding, canUseFiat else { return }
        if let maximumAmount {
            guard let input = maximumAmount.input(fiat: !fiatEntry, price: price, currency: currency) else { return }
            amount = input
            fiatEntry.toggle()
            OathSendUnitPreference.save(fiat: fiatEntry, in: preferences)
            return
        }
        let raw = try? atomic(locale: locale)
        let units = raw.flatMap { OathSendAmount.units($0, decimals: holding.decimals) }
        if fiatEntry { amount = units ?? "" }
        else if let price, let units, let value = Decimal(string: units, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN {
            // Switching to fiat is a new editable amount; show all significant
            // price digits, not the two-decimal display approximation.
            let product = value * price
            amount = product.isNaN ? "" : NSDecimalNumber(decimal: product).stringValue
        } else { amount = "" }
        fiatEntry.toggle()
        OathSendUnitPreference.save(fiat: fiatEntry, in: preferences)
    }

    func enter(_ key: OathSendKeypadInput.Key, locale: Locale) {
        xrplAccountClosure = nil
        guard let holding else { return }
        if let maximumAmount {
            guard let entry = maximumAmount.edited(by: key,
                preferredFiat: OathSendUnitPreference.isFiat(in: preferences),
                price: price, currency: currency, decimals: holding.decimals, locale: locale) else { return }
            self.maximumAmount = nil
            fiatEntry = entry.fiat
            amount = entry.amount
            return
        }
        let input = OathSendKeypadInput.applying(key, to: amount, fiat: fiatEntry, decimals: holding.decimals, locale: locale)
        guard input != amount else { return }
        amount = input
    }

    func changeRecipient() {
        xrplAccountClosure = nil
        reviewAtomic = nil; reviewPrice = nil; reviewCurrency = nil
        path = [.recipient]
    }

    private func updateEntryAvailability() {
        guard let holding else { return }
        // Optional market data may be absent. This is a native-entry fallback,
        // not an app failure; provider failures remain reported at transport.
        let entry = OathSendUnitPreference.availableEntry(fiat: fiatEntry, amount: amount,
                                                         price: price, decimals: holding.decimals)
        if entry.fiat != fiatEntry { maximumAmount = nil }
        fiatEntry = entry.fiat
        amount = entry.amount
        if let maximumAmount {
            // Price updates may update the label, never the selected quantity.
            // Balance decreases are still rejected by amountFailure/review.
            if let input = maximumAmount.input(fiat: fiatEntry, price: price, currency: currency) {
                amount = input
            } else {
                self.maximumAmount = nil
                amount = ""
            }
        }
    }

    private func resetDraft() {
        path = []; holdingID = nil; address = ""; memo = ""; stellarMemoType = .text; amount = ""
        maximumAmount = nil; xrplAccountClosure = nil
        recipientName = nil; addressError = false; memoError = false
        fiatEntry = OathSendUnitPreference.isFiat(in: preferences)
        reviewAtomic = nil; reviewPrice = nil; reviewCurrency = nil
        replaceable = false; onChainMessage = ""; reviewOptions = .init()
    }
}
