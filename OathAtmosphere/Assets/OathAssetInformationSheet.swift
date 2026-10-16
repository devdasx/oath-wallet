import SwiftUI
import OathDatabase
import OathMarketData

struct OathAssetInformationSheet: View {
    let holding: Holding
    let networkName: String
    let currency: String
    let model: OathAssetDetailModel
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.locale) private var locale
    @State private var copied = false

    var body: some View {
        OathWalletSheet(title: .assetInformation) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 10) {
                    OathAssetLogo(holding: holding, information: model.information?.value, size: 64)
                    Text(strings.invariant(model.information?.value.name ?? holding.name))
                        .oathFont(.title2, weight: .semibold).multilineTextAlignment(.center)
                    Text(strings.invariant(holding.symbol)).oathFont(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                VStack(spacing: 18) {
                    detail(.tokenNetwork, networkName)
                    detail(.assetSymbol, holding.symbol)
                    detail(.assetType, strings.text(holding.reference == "native" ? .assetNativeCoin : .assetToken))
                    // Classic XRPL currencies have floating precision, not a
                    // fixed number of decimal places. Never expose storage scale.
                    if !(holding.networkID == "xrpl" && holding.reference.contains(".")) {
                        detail(.tokenDecimals, strings.number(holding.decimals))
                    }
                    if let information = model.information?.value {
                        if let caps = information.marketCaps {
                            // Use the selected currency when supplied; an API
                            // USD fallback must keep its own currency label.
                            let code = caps[currency.lowercased()] == nil ? "USD" : currency
                            if let cap = caps[code.lowercased()] {
                                detail(.assetMarketCap, cap.formatted(.currency(code: code).locale(locale)))
                            }
                        }
                        if let supply = information.totalSupply {
                            detail(.assetTotalSupply, supplyText(supply))
                        }
                        if let supply = information.circulatingSupply {
                            detail(.assetCirculatingSupply, supplyText(supply))
                        }
                    }
                }
                if holding.reference != "native" {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(strings.text(.tokenContract)).oathFont(.caption).foregroundStyle(.secondary)
                        Text(holding.reference).font(.system(.footnote, design: .monospaced))
                            .environment(\.layoutDirection, .leftToRight).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("asset.contract")
                    }
                    OathActionButton(title: strings.text(copied ? .addressCopied : .tokenCopyAddress), appearance: .secondary) {
                        OathClipboard.copy(holding.reference); copied = true
                    }.oathActionArea(existingInset: 20)
                }
                if let saved = model.information {
                    if !saved.value.description.isEmpty {
                        Text(strings.text(.assetAbout)).oathFont(.headline)
                        Text(saved.value.description).oathFont(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("asset.description")
                    }
                    if let website = saved.value.website.flatMap(MarketDecoding.safeURL) {
                        Link(destination: website) {
                            OathSettingsRow(title: strings.text(.assetWebsite), icon: "globe", value: website.host)
                        }.buttonStyle(OathSettingsRowButtonStyle()).padding(.horizontal, -20)
                    }
                    Text((model.informationFailed ? strings.text(.assetSavedInformation) + " · " : "") +
                         saved.fetchedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(strings.language.locale)))
                        .oathFont(.caption2).foregroundStyle(.secondary)
                } else if model.loading {
                    ProgressView(strings.text(.assetMarketLoading)).frame(maxWidth: .infinity)
                } else {
                    Text(strings.text(.assetInformationUnavailable)).oathFont(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("asset.informationUnavailable")
                }
            }
        }
    }
    private func supplyText(_ value: Decimal) -> String {
        value.formatted(.number.locale(locale).precision(.significantDigits(1...12))) + " " + holding.symbol
    }

    private func detail(_ key: OathStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(strings.text(key)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(strings.invariant(value)).multilineTextAlignment(.trailing)
                .accessibilityIdentifier("asset.info.value.\(key.rawValue)")
        }.oathFont(.body)
    }
}

