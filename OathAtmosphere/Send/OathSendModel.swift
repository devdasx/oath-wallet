import OathDiagnostics
import Foundation
import OathAnkr
import Observation
import OathDatabase
import OathBitcoin

@MainActor @Observable
final class OathSendModel {
    enum Step: Hashable { case recipient, amount, review }
    struct ScannedAssetResolution: Identifiable {
        let id = UUID()
        let recipient: OathScannedRecipient
    }
    private(set) var scannedAssetResolution: ScannedAssetResolution?
    /// An address-book entry fixes the picker network without guessing from
    /// address syntax (the same EVM address can belong to several networks).
    let initialRecipient: SendRecipient?
    var walletID: String { didSet { if walletID != oldValue { xrplAccountClosure = nil; scannedAssetResolution = nil } } }
    var holdingID: String?
    var path: [Step] = [] { didSet { if !path.isEmpty { scannedAssetResolution = nil } } }
    var query = "" { didSet { if query != oldValue { scannedAssetResolution = nil } } }
    var address = "" { didSet { if address != oldValue { xrplAccountClosure = nil; pendingCatalogScan = nil; paymentNote = nil; solanaReferences = [] } } }
    var memo = "" { didSet { if memo != oldValue { xrplAccountClosure = nil; pendingCatalogScan = nil } } }
    var stellarMemoType: StellarSendMemoType = .text {
        didSet { if stellarMemoType != oldValue { pendingCatalogScan = nil } }
    }
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
    private(set) var paymentNote: String?
    private(set) var solanaReferences: [String] = []
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
    private var initialSelectionPending = true
    private var initialScan: OathScannedRecipient?
    private var catalogPreview: Holding?
    private var pendingCatalogScan: OathScannedRecipient?
    @ObservationIgnored private let preferences: UserDefaults

    init(walletID: String, holdingID: String? = nil, recipient: SendRecipient? = nil,
         scannedRecipient: OathScannedRecipient? = nil, preferences: UserDefaults = .standard) {
        self.walletID = walletID
        initialRecipient = recipient
        self.preferences = preferences
        fiatEntry = OathSendUnitPreference.isFiat(in: preferences)
        initialHoldingID = holdingID
        initialScan = scannedRecipient
    }

    var recipientNetworks: Set<OathImportChain>? {
        initialRecipient.map { Set(OathImportChain(rawValue: $0.networkID).map { [$0] } ?? []) }
    }

    var holding: Holding? { snapshot?.holdings.first { $0.id == holdingID } ?? catalogPreview }
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
    var supportsEVMSend: Bool { chain.flatMap { EVMSendNetwork(rawValue:$0.rawValue) }?.isTestnet == false && (chain != .arc || snapshot?.wallet.kind == "evmMultisig") }
    var supportsArcSend: Bool { chain == .arc && !supportsEVMSend }
    var supportsThorchainSend: Bool { chain == .thorchain }
    var supportsAptosSend: Bool { chain == .aptos }
    var supportsPolkadotSend: Bool { chain == .polkadot }
    var supportsNearSend: Bool { chain == .near }
    var supportsTronSend: Bool { chain == .tron }
    var supportsStellarSend: Bool { chain == .stellar }
    var supportsXrplSend: Bool { chain == .xrpl }
    var canOfferXrplAccountClosure: Bool {
        supportsXrplSend && holding?.reference == "native" && holding?.amountAtomic == "1000000"
    }
    var supportsSend: Bool {
        guard let chain, OathTrackedSendChain(rawValue: chain.id) != nil else { return false }
        return supportsPolkadotSend || supportsEVMSend || supportsArcSend || supportsBitcoinSend || supportsSuiSend || supportsXrplSend || supportsStellarSend || supportsTronSend || supportsNearSend || supportsSolanaSend || supportsAptosSend || supportsThorchainSend || supportsTonSend
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

    struct RecipientDetail: Identifiable {
        enum Kind: String { case memo, onChainMessage, paymentNote }
        let kind: Kind
        let title: OathStringKey
        let value: String
        var id: String { kind.rawValue }
        var isEditable: Bool { kind != .paymentNote }
    }

    var recipientDetails: [RecipientDetail] {
        var details: [RecipientDetail] = []
        if memoKind != nil, !memo.isEmpty {
            let title: OathStringKey = supportsXrplSend ? .sendDestinationTagLabel
                : supportsStellarSend ? stellarMemoLabel : .wcTransactionMemo
            details.append(.init(kind: .memo, title: title, value: memo))
        }
        if supportsBitcoinSend, !onChainMessage.isEmpty {
            details.append(.init(kind: .onChainMessage, title: .sendOnChainMessage, value: onChainMessage))
        }
        if let paymentNote, !paymentNote.isEmpty {
            details.append(.init(kind: .paymentNote, title: .scannerRequestNote, value: paymentNote))
        }
        return details
    }

    /// Missing XRP/Stellar routing information needs an opportunity to edit.
    /// Continue on Recipient remains explicit consent to send without a memo.
    func validateScannedRecipient() -> Bool {
        validateRecipient() && !((supportsXrplSend || supportsStellarSend) && memo.isEmpty)
    }
    var holdings: [Holding] {
        // WalletSnapshot already uses the shared AssetOrdering policy. Keep
        // that order; sorting here reparses atomic balances/prices on MainActor
        // and was repeated by every lazy row's separator check while scrolling.
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return (snapshot?.holdings ?? []).filter { holding in
            guard OathImportChain(rawValue: holding.networkID) != nil else { return false }
            guard initialRecipient == nil || initialRecipient?.networkID == holding.networkID else { return false }
            return words.allSatisfy { word in
                [holding.name, holding.symbol, holding.networkID, holding.reference].contains {
                    $0.localizedStandardContains(word)
                }
            }
        }
    }

    func observe(currency: String, database sourceDatabase: OathDatabase? = nil) async {
        let token = UUID(), source = walletID
        generation = token; loading = true; failed = false
        if snapshot?.wallet.id != source { snapshot = nil }
        do {
            let database = if let sourceDatabase { sourceDatabase } else { try await OathDataEnvironment.shared.database() }
            for try await snapshot in database.observeWallet(walletID: source, currency: currency) {
                guard !Task.isCancelled, generation == token, walletID == source else { return }
                let old = holding
                let previousCurrency = self.snapshot?.currency
                self.snapshot = snapshot
                if let preview = catalogPreview {
                    if snapshot.holdings.contains(where: { $0.id == preview.id }) {
                        catalogPreview = nil
                        if let scan = pendingCatalogScan, let chain {
                            pendingCatalogScan = nil
                            if !receiveScan(scan, chain: chain) { addressError = true }
                        }
                    } else if !snapshot.accounts.contains(where: { $0.id == preview.accountID && $0.networkID == preview.networkID }) {
                        resetDraft()
                    }
                }
                if let previousCurrency, previousCurrency != snapshot.currency, fiatEntry {
                    // Keep the chosen unit, but never reinterpret a value
                    // entered in another currency as the new currency.
                    amount = ""
                    maximumAmount = nil
                    if path.contains(.review) { path.removeAll { $0 == .review } }
                }
                loading = false; failed = false
                if initialSelectionPending {
                    prepareInitialSelection(from: snapshot)
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
        generation = UUID(); initialHoldingID = nil; initialSelectionPending = true; initialScan = nil; resetDraft()
        snapshot = nil; query = ""; walletID = id
    }

    /// Resolve the opening route once, from persisted wallet data, before first
    /// render when available. Returning to the picker must not trigger a redirect.
    func prepareInitialSelection(from snapshot: WalletSnapshot) {
        guard initialSelectionPending, snapshot.wallet.id == walletID else { return }
        initialSelectionPending = false
        self.snapshot = snapshot
        let target = initialHoldingID
        initialHoldingID = nil
        let scan = initialScan
        initialScan = nil
        if let target {
            if let item = snapshot.holdings.first(where: { $0.id == target }) {
                choose(item, from: snapshot, scannedRecipient: scan)
            }
            return
        }
        if let scan {
            guard scan.hasExactAsset,
                  snapshot.accounts.filter({ account in scan.networks.contains(where: { $0.id == account.networkID }) }).count == 1 else { return }
            let matches = snapshot.holdings.filter {
                scan.matchesAsset(networkID: $0.networkID, reference: $0.reference, symbol: $0.symbol)
            }
            // Multiple accounts on the same network still need an explicit choice.
            if matches.count == 1, let item = matches.first {
                startScannedSend(item, from: snapshot, recipient: scan)
            } else if matches.isEmpty, let reference = scan.token, reference != "native" {
                scannedAssetResolution = .init(recipient: scan)
            }
            return
        }
        // Token networks keep asset search available even with only a native
        // holding. Wallet origin (private key or multisig) does not change this.
        guard scan == nil, snapshot.accounts.count == 1,
              let network = snapshot.accounts.first.flatMap({ OathImportChain(rawValue: $0.networkID) }),
              !network.supportsTokens, query.isEmpty, path.isEmpty, holdingID == nil else { return }
        let candidates = holdings.filter {
            scan?.matchesAsset(networkID: $0.networkID, reference: $0.reference) ?? true
        }
        guard candidates.count == 1, let item = candidates.first else { return }
        choose(item, from: snapshot, scannedRecipient: scan)
    }

    /// Resolve an exact but unsaved asset once. Late metadata must never reopen
    /// a route after a manual selection, search, wallet change or cancellation.
    func resolveScannedAsset(using resolve: @MainActor (OathScannedRecipient, WalletSnapshot) async -> (Holding, WalletSnapshot)?) async {
        guard let request = scannedAssetResolution, let snapshot, snapshot.wallet.id == walletID else { return }
        let resolved = await resolve(request.recipient, snapshot)
        guard !Task.isCancelled, scannedAssetResolution?.id == request.id,
              walletID == snapshot.wallet.id, path.isEmpty, holdingID == nil else { return }
        scannedAssetResolution = nil
        guard let (holding, updated) = resolved else { return }
        startScannedSend(holding, from: updated, recipient: request.recipient)
    }

    /// Catalog identity is enough for recipient entry. Amounts and signing
    /// continue to require a real persisted holding from the database observer.
    func choose(_ holding: Holding, from snapshot: WalletSnapshot, scannedRecipient: OathScannedRecipient? = nil) {
        guard snapshot.wallet.id == walletID,
              initialRecipient == nil || initialRecipient?.networkID == holding.networkID,
              snapshot.accounts.contains(where: { $0.id == holding.accountID && $0.networkID == holding.networkID }),
              holding.isCatalogPreview || snapshot.holdings.contains(where: { $0.id == holding.id }) else { return }
        self.snapshot = snapshot
        choose(holding, scannedRecipient: scannedRecipient)
    }

    /// Asset scans may skip recipient entry only after the complete request and
    /// the normal recipient/self-transfer rules pass for the selected holding.
    @discardableResult func startScannedSend(_ holding: Holding, from snapshot: WalletSnapshot, recipient: OathScannedRecipient) -> Bool {
        guard snapshot.wallet.id == walletID,
              snapshot.accounts.contains(where: { $0.id == holding.accountID && $0.networkID == holding.networkID }),
              holding.isCatalogPreview || snapshot.holdings.contains(where: { $0.id == holding.id }),
              recipient.matchesAsset(networkID: holding.networkID, reference: holding.reference, symbol: holding.symbol) else { return false }
        choose(holding, from: snapshot, scannedRecipient: recipient)
        guard holdingID == holding.id, !addressError, validateRecipient() else { return false }
        // choose keeps XRP/Stellar on Recipient when their routing field is absent.
        return true
    }

    func choose(_ holding: Holding, scannedRecipient: OathScannedRecipient? = nil) {
        guard initialRecipient == nil || initialRecipient?.networkID == holding.networkID else { return }
        initialSelectionPending = false; initialHoldingID = nil; initialScan = nil
        resetDraft(); holdingID = holding.id; path = [.recipient]
        catalogPreview = holding.isCatalogPreview ? holding : nil
        updateEntryAvailability()
        if let initialRecipient {
            setRecipient(initialRecipient)
            // Known does not mean valid: preserve checksum, memo and self-send
            // rules. Invalid/stale entries remain on the recipient form.
            if validateRecipient() { path = [.amount] }
        } else if var scannedRecipient, let chain {
            // A different explicitly selected asset can reuse the recipient,
            // but must never inherit another asset's amount or token identity.
            if !scannedRecipient.matchesAsset(networkID: holding.networkID, reference: holding.reference, symbol: holding.symbol) {
                scannedRecipient.amount = nil; scannedRecipient.token = nil; scannedRecipient.tokenSymbol = nil; scannedRecipient.solanaReferences = []
            }
            if !receiveScan(scannedRecipient, chain: chain) {
                // Expected stale/incompatible scan validation. No partial payload is
                // applied, and no scanned contents enter diagnostics.
                addressError = true
            } else if validateScannedRecipient() {
                path = [.amount]
            }
        }
    }

    /// Commit all supported payment fields together, after asset selection.
    /// A token/chain mismatch never partially overwrites the current draft.
    @discardableResult func receiveScan(_ result: OathScannedRecipient, chain: OathImportChain) -> Bool {
        guard let holding, chain.rawValue == holding.networkID,
              result.matchesAsset(networkID: holding.networkID, reference: holding.reference, symbol: holding.symbol),
              result.solanaReferences.isEmpty || chain == .solana,
              let decoded = result.decoded(on: chain) else { return false }
        var scannedAmount: String?
        if let amount = result.amount, !holding.isCatalogPreview {
            if result.amountIsAtomic {
                guard let units = OathSendAmount.units(amount,
                    decimals: result.atomicAmountDecimals(networkID: holding.networkID, assetDecimals: holding.decimals)) else { return false }
                scannedAmount = units
            } else {
                let isZero = OathScanParser.normalizedAmount(amount, atomic: false) != nil && amount.allSatisfy { $0 == "0" || $0 == "." }
                guard isZero || (try? OathSendAmount.atomic(amount, decimals: holding.decimals, locale: Locale(identifier: "en_US_POSIX"))) != nil else { return false }
                scannedAmount = amount
            }
        }
        let memoType = StellarSendMemoType(rawValue: decoded.memoType ?? "text") ?? .text
        guard chain == .stellar ? (try? StellarSendMemo(type: memoType, value: decoded.memo ?? "").validate()) != nil
            : OathSendRecipientRules.validMemo(decoded.memo ?? "", networkID: chain.rawValue) else { return false }
        address = decoded.address; memo = decoded.memo ?? ""; stellarMemoType = memoType; recipientName = nil
        paymentNote = result.displayNote; solanaReferences = result.solanaReferences
        addressError = false; memoError = false
        if let scannedAmount { fiatEntry = false; amount = scannedAmount; maximumAmount = nil }
        pendingCatalogScan = holding.isCatalogPreview && result.amount != nil ? result : nil
        return true
    }

    func setRecipient(_ entry: SendRecipient) {
        guard entry.networkID == holding?.networkID else { return }
        pendingCatalogScan = nil
        address = entry.address; recipientName = entry.name; memo = ""; stellarMemoType = .text
        paymentNote = nil; solanaReferences = []
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
        guard let holding, !holding.isCatalogPreview else { throw OathSendAmount.Failure.invalid }
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
            // Fiat entry uses at most two decimals; native entry stays exact.
            amount = OathSendAmount.fiatInput(value * price) ?? ""
        } else { amount = "" }
        fiatEntry.toggle()
        OathSendUnitPreference.save(fiat: fiatEntry, in: preferences)
    }

    func enter(_ key: OathSendKeypadInput.Key, locale: Locale) {
        xrplAccountClosure = nil
        guard let holding, !holding.isCatalogPreview else { return }
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
        scannedAssetResolution = nil
        catalogPreview = nil
        pendingCatalogScan = nil
        path = []; holdingID = nil; address = ""; memo = ""; stellarMemoType = .text; amount = ""
        maximumAmount = nil; xrplAccountClosure = nil
        recipientName = nil; paymentNote = nil; solanaReferences = []; addressError = false; memoError = false
        fiatEntry = OathSendUnitPreference.isFiat(in: preferences)
        reviewAtomic = nil; reviewPrice = nil; reviewCurrency = nil
        replaceable = false; onChainMessage = ""; reviewOptions = .init()
    }
}

#if DEBUG && targetEnvironment(simulator)
extension OathSendModel {
    /// Synthetic display data only; never enters preparation, signing, or storage.
    static func resultVisualFixture() -> OathSendModel {
        let model = OathSendModel(walletID: "result-visual-fixture")
        let data = Data(#"{"accountID":"fixture","networkID":"ethereum","address":"0x0000000000000000000000000000000000000001","assetID":"ethereum:native","reference":"native","name":"Ethereum","symbol":"ETH","decimals":18,"transactionCount":0}"#.utf8)
        model.catalogPreview = try! JSONDecoder().decode(Holding.self, from: data)
        model.address = "0x0000000000000000000000000000000000000002"
        model.reviewAtomic = "1000000000000000"
        model.reviewPrice = 2400
        model.reviewCurrency = "USD"
        return model
    }
}
#endif
