import OathDiagnostics
import SwiftUI
import Observation
import OathDatabase
import OathExchangeRates

@MainActor @Observable private final class OathCurrencyModel {
    var snapshot: USDExchangeRates?
    var loading = true
    var refreshing = false
    var failed = false

    func observe() async {
        do {
            let database = try await OathDataEnvironment.shared.database()
            for try await snapshot in database.observeExchangeRates() {
                self.snapshot = snapshot
                loading = false
            }
        } catch { OathDiagnostics.record(error); if !Task.isCancelled { loading = false; failed = true } }
    }

    func refresh(retryNow: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            snapshot = try await OathExchangeRateEnvironment.shared.refresh(retryNow: retryNow)
            failed = false
        } catch { OathDiagnostics.record(error); if !Task.isCancelled { failed = true } }
    }
}

struct OathCurrencyPage: View {
    @Environment(OathAppSettings.self) private var settings
    @Environment(\.oathLocalizer) private var strings
    @State private var model = OathCurrencyModel()
    @State private var query = ""
    @State private var selecting = false
    @State private var saveFailed = false
    @State private var deviceLocale = Locale.current

    private var currencies: CurrencyCatalog.Sections {
        CurrencyCatalog.sections(availableCodes: model.snapshot?.rates.keys.map { $0 } ?? [],
            selectedCode: settings.currency, deviceLocale: deviceLocale,
            query: query, displayLocale: strings.language.locale)
    }

    var body: some View {
        let currencies = self.currencies
        List {
            if !currencies.mostUsed.isEmpty {
                Section {
                    ForEach(currencies.mostUsed, id: \.self) { currencyRow($0) }
                    if !currencies.others.isEmpty { OathSettingsListSectionRule() }
                } header: {
                    sectionTitle(.mostUsedCurrencies)
                }
                .listSectionSeparator(.hidden)
            }
            if !currencies.others.isEmpty {
                Section {
                    ForEach(currencies.others, id: \.self) { currencyRow($0) }
                } header: {
                    sectionTitle(.allCurrencies)
                }
                .listSectionSeparator(.hidden)
            }
            if !currencies.isEmpty {
                OathSettingsListSectionRule()
                rateStatus
                    .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 24, trailing: 20))
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
        }
        .id(strings.language.isRightToLeft)
        .listStyle(.plain).scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .overlay {
            if currencies.isEmpty {
                OathEmptyStateScrollView {
                    OathEmptyState(strings.text(.noSearchResults), systemImage: "magnifyingglass",
                                   description: strings.format(.noSearchResultsDetail, query))
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(strings.text(.searchCurrencies)))
        .task { await model.observe() }
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            deviceLocale = .current
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            deviceLocale = .current
        }
        .oathHapticFeedback(.error, trigger: saveFailed, when: saveFailed)
        .alert(strings.text(.preferencesSaveFailed), isPresented: $saveFailed) {
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) {}
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) {}
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        }
        .accessibilityIdentifier("preferences.currency.list")
    }

    private func currencyRow(_ code: String) -> some View {
        OathButton {
            guard !selecting, code != settings.currency else { return }
            selecting = true
            Task {
                defer { selecting = false }
                do { try await settings.selectCurrency(code) }
                catch { OathDiagnostics.record(error); saveFailed = true }
            }
        } label: {
            OathSettingsRow(title: CurrencyCatalog.name(code, locale: strings.language.locale),
                value: strings.invariant(code), accessory: .selection(settings.currency == code))
        }
        .disabled(selecting || (code != "USD" && model.snapshot?.rates[code] == nil))
        .buttonStyle(OathSettingsRowButtonStyle())
        .accessibilityAddTraits(settings.currency == code ? .isSelected : [])
        .accessibilityIdentifier("preferences.currency.\(code)")
        .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
    }

    private func sectionTitle(_ title: OathStringKey) -> some View {
        Text(strings.text(title))
            .oathFont(.subheadline, weight: .semibold)
            .foregroundStyle(.secondary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }

    private var rateStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.refreshing || model.loading {
                ProgressView(strings.text(.loadingExchangeRates)).oathFont(.footnote)
            }
            if model.failed {
                Text(strings.text(model.snapshot == nil ? .exchangeRatesUnavailable : .exchangeRatesCached))
                    .oathFont(.footnote).foregroundStyle(.secondary)
                OathActionButton(title: strings.text(.tryAgain), appearance: .secondary) { Task { await model.refresh(retryNow: true) } }
                    .oathActionArea(existingInset: 20)
                    .disabled(model.refreshing)
            }
            if let snapshot = model.snapshot {
                let date = Date(timeIntervalSince1970: snapshot.observedAt)
                Text(strings.format(.exchangeRatesDate, date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted,
                    locale: strings.language.locale, timeZone: TimeZone(secondsFromGMT: 0)!))))
                    .oathFont(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OathAppIconPage: View {
    @Environment(OathAppSettings.self) private var settings
    @Environment(\.oathLocalizer) private var strings
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(OathAppIcon.allCases) { icon in
                    OathButton {
                        Task {
                            await OathDiagnostics.$operationID.withValue(UUID()) {
                                do { try await settings.selectAppIcon(icon) }
                                catch {
                                    OathDiagnostics.record(error, component: "app_icon", operation: "change_icon")
                                    // A dismissed native request leaves the selected icon unchanged.
                                    if !OathDiagnostics.isExpectedCancellation(error) { failed = true }
                                }
                            }
                        }
                    } label: {
                        OathSettingsRow(title: strings.text(icon.titleKey), icon: "app",
                            accessory: .selection(settings.appIcon == icon), imageAsset: icon.preview)
                    }
                    .buttonStyle(OathSettingsRowButtonStyle())
                    .disabled(settings.changingAppIcon || !UIApplication.shared.supportsAlternateIcons)
                    .accessibilityAddTraits(settings.appIcon == icon ? .isSelected : [])
                    .accessibilityIdentifier("preferences.appIcon.\(icon.rawValue)")
                }
                if settings.changingAppIcon { ProgressView().padding() }
                if !UIApplication.shared.supportsAlternateIcons {
                    Text(strings.text(.appIconUnavailable)).oathFont(.footnote).foregroundStyle(.secondary).padding(20)
                }
            }
            .padding(.vertical, 12).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
        .oathHapticFeedback(.error, trigger: failed, when: failed)
        .alert(strings.text(.appIconChangeFailed), isPresented: $failed) {
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) {}
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) {}
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        }
        .accessibilityIdentifier("preferences.appIcon.list")
        .task { await settings.refreshAppIcon() }
    }
}
