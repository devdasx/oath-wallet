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
    @State private var showsContract = false

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
                    if !holding.isCatalogPreview && !(holding.networkID == "xrpl" && holding.reference.contains(".")) {
                        detail(.tokenDecimals, strings.number(holding.decimals))
                    }
                    if let information = model.information?.value {
                        if let caps = information.marketCaps {
                            // Use the selected currency when supplied; an API
                            // USD fallback must keep its own currency label.
                            let code = caps[currency.lowercased()] == nil ? "USD" : currency
                            if let cap = caps[code.lowercased()] {
                                detail(.assetMarketCap, OathAssetAmountFormat(locale: locale, selectedCurrencyCode: code).money(cap))
                            }
                        }
                        if let supply = information.totalSupply {
                            detail(.assetTotalSupply, supplyText(supply))
                        }
                        if let supply = information.circulatingSupply {
                            detail(.assetCirculatingSupply, supplyText(supply))
                        }
                    }
                    if holding.reference != "native" {
                        contractRow
                    }
                }
                if let saved = model.information {
                    if !saved.value.description.isEmpty {
                        Text(strings.text(.assetAbout)).oathFont(.headline)
                        Text(saved.value.description).oathFont(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("asset.description")
                    }
                } else if model.loading && !holding.isCatalogPreview {
                    ProgressView(strings.text(.assetMarketLoading)).frame(maxWidth: .infinity)
                } else {
                    Text(strings.text(.assetInformationUnavailable)).oathFont(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("asset.informationUnavailable")
                }
            }
        }
        .sheet(isPresented: $showsContract) {
            OathWalletSheet(title: .tokenContract) {
                VStack(spacing: 20) {
                    OathAddressText(address: holding.reference, identifier: "asset.contract.fullAddress")
                        .padding(.vertical, 16)
                    OathActionButton(title: strings.text(copied ? .addressCopied : .tokenCopyAddress), appearance: .secondary) {
                        OathClipboard.copy(holding.reference)
                        copied = true
                    }
                    .accessibilityIdentifier("asset.contract.copy")
                    .oathActionArea(existingInset: 20)
                }
            }.oathLanguage(strings.language)
        }
    }

    private var contractRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(strings.text(.tokenContract)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            OathButton(feedback: .navigate) {
                copied = false
                showsContract = true
            } label: {
                Text(holding.reference)
                    .underline(pattern: .dot, color: .gray.opacity(0.65))
                    .lineLimit(1).truncationMode(.middle)
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.primary)
            .accessibilityLabel(strings.text(.tokenContract))
            .accessibilityValue(holding.reference)
            .accessibilityHint(strings.text(.sendShowAddress))
            .accessibilityIdentifier("asset.contract")
        }.oathFont(.body)
    }
    private func supplyText(_ value: Decimal) -> String {
        OathAssetAmountFormat(locale: locale).native(value, ticker: holding.symbol)
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

