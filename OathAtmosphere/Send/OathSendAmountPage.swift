import SwiftUI
import OathBitcoin
import OathAnkr
import OathDiagnostics

struct OathSendAmountPage: View {
    @Bindable var model: OathSendModel
    let session: OathWalletSession
    let onReview: @MainActor () -> Bool
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsOptions = false
    @State private var recipientDetail: OathSendModel.RecipientDetail?
    @State private var pendingDetailEdit: OathSendModel.RecipientDetail.Kind?
    @State private var closureTask: Task<Void,Never>?
    @State private var checkingClosure = false
    @State private var closureOffer: XrplSendPlan?
    @State private var closureError: OathStringKey?
    @State private var showsClosure = false
    @State private var format = OathSendAmountFormat(locale: Locale(identifier: "en_US"), currency: "USD")
    private var reviewing: Bool { model.path.last == .review }
    private var failure: OathSendAmount.Failure? {
        model.amountFailure(locale: strings.language.locale)
    }
    private var canContinue: Bool {
        model.holding != nil && failure == nil && !model.failed && !model.loading && model.bitcoinOptionsValid && !reviewing && !checkingClosure
    }
    private var formatID: String { strings.language.locale.identifier + "/" + model.currency }
    private var motion: Animation? { reduceMotion ? nil : .smooth(duration: 0.22) }
    private var replacement: AnyTransition { reduceMotion ? .opacity : AnyTransition(.blurReplace) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 22) {
                        VStack(spacing: 8) {
                            recipient
                            ForEach(model.recipientDetails) { detail in
                                recipientDetailCapsule(detail)
                            }
                        }
                        if model.holding != nil {
                            amountEntry
                            available
                            if let message = errorMessage {
                                Label(strings.text(message), systemImage: "exclamationmark.circle")
                                    .oathFont(.footnote).foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("send.amount.error")
                            }
                        }
                    }
                    .padding(20).frame(maxWidth: 600)
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .center)
                }
            }
            if model.holding != nil {
                // The footer keeps its natural height at the safe-area bottom.
                // Center the amount group in the remaining scrollable space.
                VStack(spacing: 16) {
                    Text(strings.text(.sendAmountReviewHint)).oathFont(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                    keypad
                }
                .padding(.top, 12).padding(.bottom, 8)
                .background(Color(uiColor: OathSurfaceColors.canvas))
            }
        }
        .toolbar {
            if model.supportsBitcoinSend {
                ToolbarItem(placement: .topBarTrailing) {
                    OathButton(feedback: .navigate) { showsOptions = true } label: {
                        Label(strings.text(.sendOptions), systemImage: "ellipsis")
                    }.labelStyle(.iconOnly).oathNeutralControl()
                        .disabled(reviewing)
                        .accessibilityIdentifier("send.options")
                }
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
            }
            OathToolbarAction(title: .continueAction, kind: .navigation, isEnabled: canContinue, isWorking: reviewing, identifier: "send.amount.continue") {
                if !onReview() { OathHaptics.shared.play(.error) }
            }
        }
        .sheet(isPresented: $showsOptions) {
            if let network = model.chain.flatMap({ UTXONetwork(rawValue: $0.rawValue) }) {
                OathSendOptionsSheet(network: network, replaceable: model.replaceable, message: model.onChainMessage) { replaceable, message in
                    model.replaceable = replaceable; model.onChainMessage = message
                }
            }
        }
        .sheet(item: $recipientDetail, onDismiss: editRecipientDetail) { detail in
            OathWalletSheet(title: detail.title) {
                VStack(alignment: .leading, spacing: 24) {
                    Text(detail.value).oathFont(.body).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("send.amount.detail.fullValue")
                    if detail.isEditable {
                        OathBottomAction(title: strings.text(.editWallets), identifier: "send.amount.detail.edit") {
                            pendingDetailEdit = detail.kind
                            recipientDetail = nil
                        }
                    }
                }.padding(.vertical, 12)
            }.oathLanguage(strings.language)
        }
        .alert(strings.text(.xrplCloseTitle), isPresented: $showsClosure) {
            if let offer = closureOffer {
                Button(strings.text(.xrplCloseReview), role: .destructive) {
                    if model.useAccountClosure(offer) {
                        if !onReview() { OathHaptics.shared.play(.error) }
                    } else { closureError = .xrplCloseUnavailable; OathHaptics.shared.play(.error) }
                    closureOffer = nil
                }
            }
            Button(strings.text(.cancel), role: .cancel) { closureOffer = nil }
        } message: {
            if let offer = closureOffer {
                Text(strings.format(.xrplCloseExplanation,
                    strings.invariant((OathSendAmount.units(offer.amount,decimals:6) ?? "0") + " XRP"),
                    strings.invariant((OathSendAmount.units(String(offer.fee),decimals:6) ?? "0") + " XRP")))
            } else { Text(strings.text(closureError ?? .xrplCloseUnavailable)) }
        }
        .onDisappear { closureTask?.cancel(); closureTask = nil; checkingClosure = false }
        .onChange(of: session.isUnlocked) { _, unlocked in
            if !unlocked { pendingDetailEdit = nil; recipientDetail = nil; showsOptions = false }
        }
        .onChange(of: formatID, initial: true) { _, _ in
            format = OathSendAmountFormat(locale: strings.language.locale, currency: model.currency)
        }
    }

    private func recipientDetailCapsule(_ detail: OathSendModel.RecipientDetail) -> some View {
        OathButton(feedback: .navigate) { recipientDetail = detail } label: {
            HStack(spacing: 8) {
                Text(strings.text(detail.title))
                    .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                Text(detail.value)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.vertical, 4)
                    .overlay(alignment: .bottom) {
                        OathSendDottedLine().stroke(.gray.opacity(0.65), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 3]))
                            .frame(height: 1)
                    }
            }.oathFont(.subheadline, weight: .medium)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        }.buttonStyle(.plain).oathNeutralControl()
            .disabled(reviewing || checkingClosure)
            .accessibilityLabel(strings.text(detail.title))
            .accessibilityValue(detail.value)
            .accessibilityIdentifier("send.amount.detail.\(detail.id)")
    }

    private func editRecipientDetail() {
        let edit = pendingDetailEdit
        pendingDetailEdit = nil
        guard session.isUnlocked, !session.resetting, model.path.last == .amount else { return }
        // Wait for dismissal before changing navigation or opening the options sheet.
        switch edit {
        case .memo: model.changeRecipient()
        case .onChainMessage: showsOptions = true
        case .paymentNote, nil: break
        }
    }

    private var recipient: some View {
        HStack(spacing: 8) {
            if let holding = model.holding {
                OathSendLogo(holding: holding, size: 26)
                Text(strings.format(.sendAssetTo, strings.invariant(holding.name)))
                    .oathFont(.subheadline, weight: .medium).lineLimit(2)
                Menu {
                    OathButton(strings.text(.sendChangeAddress), systemImage: "pencil", feedback: .navigate) {
                        model.changeRecipient()
                    }
                } label: {
                    Text(compactAddress)
                        .oathFont(.subheadline, weight: .medium)
                        .lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.8)
                        .environment(\.layoutDirection, .leftToRight)
                        .padding(.vertical, 4)
                        .overlay(alignment: .bottom) {
                            OathSendDottedLine().stroke(.gray.opacity(0.65), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 3]))
                                .frame(height: 1)
                        }
                }.tint(.primary).foregroundStyle(.primary)
                    .accessibilityLabel(strings.text(.sendChangeAddress))
                    .accessibilityValue(model.address)
                    .accessibilityIdentifier("send.amount.recipient")
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private var compactAddress: String {
        let prefix = "bitcoincash:"
        let address = model.chain == .bitcoincash && model.address.lowercased().hasPrefix(prefix)
            ? String(model.address.dropFirst(prefix.count)) : model.address
        return address.count > 22 ? String(address.prefix(9)) + "…" + String(address.suffix(7)) : address
    }

    private var amountEntry: some View {
        VStack(spacing: 10) {
            if let holding = model.holding {
                Text(styledAmount(symbol: holding.symbol, decimals: holding.decimals))
                    .oathFont(.largeTitle, weight: .semibold, size: 54)
                    .lineLimit(1).minimumScaleFactor(0.25)
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .environment(\.layoutDirection, .leftToRight)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .id(model.fiatEntry).transition(replacement)
                    .accessibilityLabel(strings.text(.sendAmount))
                    .accessibilityValue(format.amount(model.amount, fiat: model.fiatEntry, symbol: holding.symbol, decimals: holding.decimals, belowFiatMinimum: maximumBelowFiatMinimum))
                    .accessibilityIdentifier("send.amount")
                HStack(spacing: 10) {
                    Text(equivalent).oathFont(.body).foregroundStyle(.secondary)
                        .lineLimit(2).minimumScaleFactor(0.7)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .accessibilityIdentifier("send.amount.equivalent")
                    if model.canUseFiat {
                        OathButton(feedback: .selection) { model.switchUnit(locale: strings.language.locale) } label: {
                            Image(systemName: "arrow.up.arrow.down").font(.body.weight(.medium))
                                .frame(width: 44, height: 44)
                                .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                        }.buttonStyle(.plain).oathNeutralControl()
                            .accessibilityLabel(strings.text(.sendSwitchUnit))
                            .accessibilityIdentifier("send.amount.switchUnit")
                    }
                }.frame(minHeight: 44)
            }
        }.padding(.top, 6)
            .animation(motion, value: model.amount)
            .animation(motion, value: model.fiatEntry)
    }

    // Max retains a positive exact quantity even if its fiat edit label rounds
    // to zero. Display the sub-cent bound instead of suggesting it is free.
    private var maximumBelowFiatMinimum: Bool {
        model.fiatEntry && model.maximumAmount != nil && model.maximumAmount?.atomic != "0" && model.amount == "0"
    }

    private func styledAmount(symbol: String, decimals: Int) -> AttributedString {
        let parts = format.amountParts(model.amount, fiat: model.fiatEntry, symbol: symbol, decimals: decimals, belowFiatMinimum: maximumBelowFiatMinimum)
        var prefix = AttributedString(parts.prefix)
        var number = AttributedString(parts.number)
        var suffix = AttributedString(parts.suffix)
        // Keep localized currency placement and ticker spacing in one Text so
        // scaling, numeric transitions and accessibility remain unchanged.
        prefix.foregroundColor = .secondary
        suffix.foregroundColor = .secondary
        number.foregroundColor = model.amount.isEmpty ? .secondary : .primary
        return prefix + number + suffix
    }

    private var available: some View {
        HStack(spacing: 10) {
            Text(balance).oathFont(.subheadline, weight: .medium).lineLimit(1).minimumScaleFactor(0.65)
            OathButton(feedback: .selection) { useMaximum() } label: {
                Text(strings.text(.sendMax))
                    .opacity(checkingClosure ? 0 : 1)
                    .oathFont(.subheadline, weight: .semibold)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(minHeight: OathInputMetrics.minimumContentHeight)
                    .background(Color.primary.opacity(0.07))
                    .clipShape(.rect(cornerRadius: OathInputMetrics.actionCornerRadius))
            }.buttonStyle(.plain)
                .overlay { if checkingClosure { ProgressView().accessibilityLabel(strings.text(.sendLoadingFee)) } }
                .disabled(model.holding?.amountAtomic == nil || model.failed || reviewing || checkingClosure)
                .accessibilityIdentifier("send.max")
        }.padding(.leading, OathInputMetrics.horizontalInset)
            .padding(.trailing, OathInputMetrics.actionInset).padding(.vertical, OathInputMetrics.actionInset)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: OathInputMetrics.cornerRadius))
    }

    private func useMaximum() {
        model.useBalance()
        // Only the final 1 XRP can offer account closure. Larger balances and
        // every token/other chain retain their ordinary Max behavior.
        guard model.canOfferXrplAccountClosure, let holding = model.holding, session.isUnlocked else { return }
        let wallet = model.walletID, recipient = model.address, memo = model.memo
        closureOffer = nil; closureError = nil; checkingClosure = true
        closureTask?.cancel()
        closureTask = Task {
            do {
                let offer = try await OathXrplSendService.shared.closureOffer(walletID:wallet,accountID:holding.accountID,
                    recipient:recipient,destinationTag:UInt32(memo),vault:session.vault)
                guard !Task.isCancelled, session.isUnlocked, model.walletID == wallet, model.holding?.id == holding.id,
                      model.address == recipient, model.memo == memo, model.holding?.amountAtomic == "1000000" else { checkingClosure = false; return }
                checkingClosure = false; closureOffer = offer; showsClosure = true
            } catch {
                // Ledger eligibility is expected validation, never log user input.
                if !XrplSendClient.closureValidation(error) {
                    OathDiagnostics.record(error,component:"xrpl_send",operation:"closure_offer",context:["chain":"xrpl"])
                }
                guard !Task.isCancelled else { return }
                checkingClosure = false
                guard session.isUnlocked, model.walletID == wallet, model.holding?.id == holding.id,
                      model.address == recipient, model.memo == memo else { return }
                // A live balance change above the reserve must not show the offer.
                guard error as? XrplSendError != .closureUnavailable else { return }
                switch error as? XrplSendError {
                case .closureTooSoon: closureError = .xrplCloseTooSoon
                case .closureObligations: closureError = .xrplCloseObligations
                case .recipientUnfunded: closureError = .xrplCloseRecipient
                case .destinationTag: closureError = .xrplTagRequired
                default: closureError = .xrplCloseUnavailable
                }
                showsClosure = true
            }
        }
    }

    /// Fixed numeric order in both writing directions, with localized digits
    /// and decimal separator. Native buttons also support VoiceOver activation.
    private var keypad: some View {
        VStack(spacing: 4) {
            ForEach(0..<4) { row in
                HStack(spacing: 0) {
                    ForEach(0..<3) { column in
                        keypadButton(key(row: row, column: column))
                    }
                }
            }
        }.environment(\.layoutDirection, .leftToRight)
            .disabled(reviewing || checkingClosure)
            .accessibilityIdentifier("send.amount.keypad")
    }

    private func key(row: Int, column: Int) -> OathSendKeypadInput.Key {
        if row < 3 { return .digit(row * 3 + column + 1) }
        return column == 0 ? .decimal : column == 1 ? .digit(0) : .delete
    }

    @ViewBuilder private func keypadButton(_ key: OathSendKeypadInput.Key) -> some View {
        let button = OathButton(feedback: .input) { model.enter(key, locale: strings.language.locale) } label: {
            Group {
                switch key {
                case .digit(let digit): Text(format.digits[digit])
                case .decimal: Text(format.decimalSeparator)
                case .delete, .clear: Image(systemName: "delete.left").font(.system(size: 26, weight: .regular))
                }
            }.oathFont(.title2, weight: .medium, size: 32)
                .frame(maxWidth: .infinity, minHeight: 64)
                .contentShape(Rectangle())
        }.buttonStyle(OathSendKeyStyle())
            .disabled(key == .delete && model.amount.isEmpty || key == .decimal && (!model.fiatEntry && model.holding?.decimals == 0 || model.amount.contains(".")))
            .accessibilityLabel(keyLabel(key))
            .accessibilityIdentifier(keyIdentifier(key))
        if key == .delete {
            button
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in clearAmount() })
                .accessibilityAction(named: Text(strings.text(.clear))) { clearAmount() }
        } else {
            button
        }
    }

    private func clearAmount() {
        guard !reviewing, !model.amount.isEmpty else { return }
        OathHaptics.shared.perform(.input) {
            model.enter(.clear, locale: strings.language.locale)
        }
    }

    private func keyLabel(_ key: OathSendKeypadInput.Key) -> String {
        switch key {
        case .digit(let digit): format.digits[digit]
        case .decimal: strings.text(.sendDecimalSeparator)
        case .delete: strings.text(.deleteDigit)
        case .clear: strings.text(.clear)
        }
    }

    private func keyIdentifier(_ key: OathSendKeypadInput.Key) -> String {
        switch key {
        case .digit(let digit): "send.keypad.digit.\(digit)"
        case .decimal: "send.keypad.decimal"
        case .delete: "send.keypad.delete"
        case .clear: "send.keypad.clear"
        }
    }

    private var balance: String {
        guard let holding = model.holding, let raw = holding.amountAtomic,
              let units = OathSendAmount.units(raw, decimals: holding.decimals) else { return strings.text(.sendBalanceUnknown) }
        if model.fiatEntry {
            // Reuse the portfolio valuation in the selected currency. This is
            // presentation only; Max still retains the exact atomic balance.
            return holding.fiatDisplayValue.map {
                OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.currency).money($0)
            } ?? strings.text(.assetPriceUnavailable)
        }
        return strings.invariant(format.number(units) + " " + holding.symbol)
    }

    private var equivalent: String {
        guard let holding = model.holding else { return "" }
        guard let price = model.price else { return strings.text(.assetPriceUnavailable) }
        guard let units = model.maximumAmount?.units ?? OathSendAmount.displayUnits(model.amount, fiat: model.fiatEntry, price: price,
                                                     decimals: holding.decimals, locale: strings.language.locale) else { return "—" }
        if model.fiatEntry { return strings.invariant("≈ " + format.number(units) + " " + holding.symbol) }
        guard let value = Decimal(string: units, locale: Locale(identifier: "en_US_POSIX")),
              !(value * price).isNaN else { return "—" }
        return "≈ " + OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: model.currency).money((value * price))
    }

    private var errorMessage: OathStringKey? {
        if let closureError { return closureError }
        if model.failed { return .sendLoadFailed }
        if failure == .balanceUnknown { return .sendBalanceUnknown }
        // Empty/zero is the normal keypad starting state, not a user error.
        guard !model.amount.isEmpty,
              !model.amount.allSatisfy({ $0 == "0" || $0 == "." }),
              !model.fiatEntry || model.price != nil else { return nil }
        switch failure {
        case .insufficient: return .sendInsufficient
        case .precision: return .sendTooPrecise
        case .invalid, .zero: return .sendAmountInvalid
        default: return nil
        }
    }
}

private struct OathSendDottedLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

private struct OathSendKeyStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
            .background(configuration.isPressed ? Color(uiColor: .tertiarySystemFill) : .clear,
                        in: RoundedRectangle(cornerRadius: 18))
    }
}
