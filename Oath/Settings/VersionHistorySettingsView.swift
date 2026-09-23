import SwiftUI

struct VersionHistorySettingsView: View {
    var body: some View {
        List {
            Group {
                Section {
                    ForEach(VersionHistoryCatalog.releases) { release in
                        VersionHistoryDisclosureRow(
                            release: release,
                            isCurrent:
                                release.version == AppBundleMetadata.version
                                    && (release.build == nil || release.build == AppBundleMetadata.build)
                        )
                    }
                } footer: {
                    Text("settings.about.history.summary")
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("settings.about.history.section")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum VersionHistoryCatalog {
    // Public App Store releases, newest first. Each feature always includes
    // localized explanatory copy so the history remains useful in every locale.
    static let releases: [VersionHistoryRelease] = [
        VersionHistoryRelease(
            version: "4.0.0",
            build: "72",
            features: [
                VersionHistoryFeature(titleKey: "brand.name", detailKey: "settings.about.history.v400.identity"),
                VersionHistoryFeature(titleKey: "network_fees.title", detailKey: "settings.about.history.v400.fees"),
                VersionHistoryFeature(titleKey: "transaction_export.title", detailKey: "settings.about.history.v400.export"),
                VersionHistoryFeature(titleKey: "wallet.home.activity.title", detailKey: "settings.about.history.v400.activity"),
                VersionHistoryFeature(titleKey: "settings.about.history.performance_reliability", detailKey: "settings.about.history.performance_reliability.detail")
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.9",
            build: "71",
            features: [
                VersionHistoryFeature(
                    titleKey: "markets.sentiment.title",
                    detailKey: "settings.about.history.v359b71.sentiment"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.9",
            build: "70",
            features: [
                VersionHistoryFeature(
                    titleKey: "settings.about.history.v358b66.markets.title",
                    detailKey: "settings.about.history.v359b70.markets"
                ),
                VersionHistoryFeature(
                    titleKey: "markets.sentiment.title",
                    detailKey: "settings.about.history.v359b70.sentiment"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.performance_reliability",
                    detailKey: "settings.about.history.v359b70.improvements"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.9",
            build: "69",
            features: [
                VersionHistoryFeature(
                    titleKey: "settings.about.history.v358b66.markets.title",
                    detailKey: "settings.about.history.v359b69.improvements"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.9",
            build: "68",
            features: [
                VersionHistoryFeature(
                    titleKey: "settings.about.history.v358b66.markets.title",
                    detailKey: "settings.about.history.v359b68.charts"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.9",
            build: "67",
            features: [
                VersionHistoryFeature(
                    titleKey: "settings.about.history.performance_reliability",
                    detailKey: "settings.about.history.v359b67.balances"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.9",
            build: "66",
            features: [
                VersionHistoryFeature(
                    titleKey: "settings.about.history.v358b66.markets.title",
                    detailKey: "settings.about.history.v358b66.markets"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.performance_reliability",
                    detailKey: "settings.about.history.v358b66.prices"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.wallets.title",
                    detailKey: "settings.about.history.v358b66.wallets"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.8",
            build: "64",
            features: [
                VersionHistoryFeature(
                    titleKey: "settings.about.history.v358.arc.title",
                    detailKey: "settings.about.history.v358.arc"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.v358.stocks.title",
                    detailKey: "settings.about.history.v358.stocks"
                ),
                VersionHistoryFeature(
                    titleKey: "success.backup.title",
                    detailKey: "settings.about.history.v358.backup"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.performance_reliability",
                    detailKey: "settings.about.history.v358.reliability"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.7",
            build: "63",
            features: [
                VersionHistoryFeature(
                    titleKey: "settings.about.history.v357.tour.title",
                    detailKey: "settings.about.history.v357.tour"
                ),
                VersionHistoryFeature(
                    titleKey: "success.backup.title",
                    detailKey: "settings.about.history.v357.backup"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.performance_reliability",
                    detailKey: "settings.about.history.v357.reliability"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.notifications.title",
                    detailKey: "settings.about.history.v357.notifications"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.wallets.title",
                    detailKey: "settings.about.history.v357.wallets"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.home.action.send",
                    detailKey: "settings.about.history.v357.send"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.security.title",
                    detailKey: "settings.about.history.v357.security"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.6",
            build: "62",
            features: [
                VersionHistoryFeature(
                    titleKey: "settings.about.history.v356.welcome.title",
                    detailKey: "settings.about.history.v356.welcome"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.language.title",
                    detailKey: "settings.about.history.v356.localization"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.asset.details.price",
                    detailKey: "settings.about.history.v356.pricing"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.appearance.title",
                    detailKey: "settings.about.history.v356.appearance"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.transaction.details.title",
                    detailKey: "settings.about.history.v356.transactions"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.security.title",
                    detailKey: "settings.about.history.v356.security"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.5",
            build: "59",
            features: [
                VersionHistoryFeature(
                    titleKey: "wallet.home.action.send",
                    detailKey: "settings.about.history.v355.build59.maximum"
                ),
                VersionHistoryFeature(
                    titleKey: "send.network_fee.title",
                    detailKey: "settings.about.history.v355.build59.fees"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.5",
            build: "58",
            features: [
                VersionHistoryFeature(
                    titleKey: "settings.appearance.title",
                    detailKey: "settings.about.history.v355.build58.home"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.transaction.details.title",
                    detailKey: "settings.about.history.v355.build58.fields"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.notifications.title",
                    detailKey: "settings.about.history.v355.build58.banners"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.5",
            build: "57",
            features: [
                VersionHistoryFeature(
                    titleKey: "wallet.home.action.send",
                    detailKey: "settings.about.history.v355.build57.slide"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.notifications.title",
                    detailKey: "settings.about.history.v355.build57.activity"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.transaction.details.title",
                    detailKey: "settings.about.history.v355.build57.details"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.performance_reliability",
                    detailKey: "settings.about.history.v355.build57.resume"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.security.title",
                    detailKey: "settings.about.history.v355.build57.secrets"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.home.action.receive",
                    detailKey: "settings.about.history.v355.build57.filters"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.transaction.details.transfer.section",
                    detailKey: "settings.about.history.v355.build57.units"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.5",
            build: "56",
            features: [
                VersionHistoryFeature(
                    titleKey: "wallet.home.action.send",
                    detailKey: "settings.about.history.v355.build56.slide"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.notifications.title",
                    detailKey: "settings.about.history.v355.build56.activity"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.transaction.details.title",
                    detailKey: "settings.about.history.v355.build56.status"
                ),
                VersionHistoryFeature(
                    titleKey: "send.network_fee.title",
                    detailKey: "settings.about.history.v355.build56.fees"
                ),
                VersionHistoryFeature(
                    titleKey: "send.coin_control.title",
                    detailKey: "settings.about.history.v355.build56.dust"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.performance_reliability",
                    detailKey: "settings.about.history.v355.build56.stability"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.wallets.backup.section",
                    detailKey: "settings.about.history.v355.build56.backup"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.4",
            build: "55",
            features: [
                VersionHistoryFeature(
                    titleKey: "settings.about.history.performance_reliability",
                    detailKey: "settings.about.history.v354.build55.interface"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.home.action.send",
                    detailKey: "settings.about.history.v354.build55.send"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.notifications.title",
                    detailKey: "settings.about.history.v354.build55.notifications"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.wallets.backup.section",
                    detailKey: "settings.about.history.v354.build55.backup"
                ),
                VersionHistoryFeature(
                    titleKey: "bitcoin.settings.silent.output.title",
                    detailKey: "settings.about.history.v354.build54.rawtr"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.section",
                    detailKey: "settings.about.history.v354.build54.interface"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.4",
            build: "54",
            features: [
                VersionHistoryFeature(
                    titleKey: "bitcoin.settings.silent.output.title",
                    detailKey: "settings.about.history.v354.build54.rawtr"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.section",
                    detailKey: "settings.about.history.v354.build54.interface"
                ),
                VersionHistoryFeature(
                    titleKey: "bitcoin.settings.title",
                    detailKey: "settings.about.history.v354.build53.brd"
                ),
                VersionHistoryFeature(
                    titleKey: "import.private_key.title",
                    detailKey: "settings.about.history.v354.build53.imports"
                ),
                VersionHistoryFeature(
                    titleKey: "import.bip38.title",
                    detailKey: "settings.about.history.v354.build53.encrypted"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.v354.core.title",
                    detailKey: "settings.about.history.v354.build53.core"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.v354.electrum.title",
                    detailKey: "settings.about.history.v354.build53.electrum"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.home.action.receive",
                    detailKey: "settings.about.history.v354.build53.discovery"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.wallets.backup.section",
                    detailKey: "settings.about.history.v354.build53.backup"
                ),
                VersionHistoryFeature(
                    titleKey: "import.bitcoin.file.choose",
                    detailKey: "settings.about.history.v354.build53.files"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.home.action.send",
                    detailKey: "settings.about.history.v354.build53.send"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.3",
            build: "52",
            features: [
                VersionHistoryFeature(
                    titleKey: "import.recovery.title",
                    detailKey: "settings.about.history.v353.build51.recovery"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.home.action.send",
                    detailKey: "settings.about.history.v353.build51.send"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.security.title",
                    detailKey: "settings.about.history.v353.build51.security"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.notifications.title",
                    detailKey: "settings.about.history.v353.build51.notifications"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.2",
            features: [
                VersionHistoryFeature(
                    titleKey: "settings.security.title",
                    detailKey: "settings.about.history.v352.build50.safety"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.performance_reliability",
                    detailKey: "settings.about.history.v352.build50.input"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.appearance.title",
                    detailKey: "settings.about.history.v352.build50.interface"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.section",
                    detailKey: "settings.about.history.v352.build49"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.performance_reliability",
                    detailKey: "settings.about.history.v352.build48"
                ),
                VersionHistoryFeature(
                    titleKey: "import.recovery.title",
                    detailKey: "settings.about.history.v352.recovery"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.v352.typing.title",
                    detailKey: "settings.about.history.v352.typing"
                ),
                VersionHistoryFeature(
                    titleKey: "import.recovery.passphrase.navigation",
                    detailKey: "settings.about.history.v352.passphrase"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.v352.navigation.title",
                    detailKey: "settings.about.history.v352.navigation"
                ),
                VersionHistoryFeature(
                    titleKey: "common.scan",
                    detailKey: "settings.about.history.v352.scanner"
                ),
                VersionHistoryFeature(
                    titleKey: "send.recipient.history.title",
                    detailKey: "settings.about.history.v352.recipients"
                ),
                VersionHistoryFeature(
                    titleKey: "send.amount.section",
                    detailKey: "settings.about.history.v352.amount"
                ),
                VersionHistoryFeature(
                    titleKey: "send.broadcast.navigation_title",
                    detailKey: "settings.about.history.v352.visibility"
                ),
                VersionHistoryFeature(
                    titleKey: "send.bitcoin.op_return.title",
                    detailKey: "settings.about.history.v352.op_return"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.transaction.details.repeat.action",
                    detailKey: "settings.about.history.v352.repeat"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.transaction.details.share_transaction_id",
                    detailKey: "settings.about.history.v352.sharing"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.language.title",
                    detailKey: "settings.about.history.v352.localization"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.v352.icon.title",
                    detailKey: "settings.about.history.v352.icon"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.wallets.backup.replace.confirm",
                    detailKey: "settings.about.history.v352.backup"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.1",
            features: [
                VersionHistoryFeature(
                    titleKey: "settings.about.history.performance_reliability",
                    detailKey: "settings.about.history.v351.navigation"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.converter.title",
                    detailKey: "settings.about.history.v351.converter"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.notifications.title",
                    detailKey: "settings.about.history.v351.notifications"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "3.5.0",
            features: [
                VersionHistoryFeature(
                    titleKey: "onboarding.carousel.open_source.title",
                    detailKey: "onboarding.carousel.open_source.message"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.search.start.title",
                    detailKey: "wallet.search.start.message"
                ),
                VersionHistoryFeature(
                    titleKey: "receive.bitcoin.address_type.silent_payments",
                    detailKey: "bitcoin.settings.silent.outputs.footer"
                ),
                VersionHistoryFeature(
                    titleKey: "send.recipient.history.title",
                    detailKey: "settings.about.history.transfer_workflow.detail"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.performance_reliability",
                    detailKey:
                        "settings.about.history.performance_reliability.detail"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "2.40.12",
            features: [
                VersionHistoryFeature(
                    titleKey: "bitcoin.settings.title",
                    detailKey: "bitcoin.settings.aggregate.footer"
                ),
                VersionHistoryFeature(
                    titleKey: "receive.bitcoin.address_type.silent_payments",
                    detailKey: "bitcoin.settings.silent.outputs.footer"
                ),
                VersionHistoryFeature(
                    titleKey: "muun.recovery.title",
                    detailKey: "muun.recovery.method.emergency.detail"
                ),
                VersionHistoryFeature(
                    titleKey: "send.recipient.history.title",
                    detailKey: "settings.about.history.transfer_workflow.detail"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.tools.broadcast_bitcoin.title",
                    detailKey: "settings.tools.broadcast_bitcoin.input.footer"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "2.40.11",
            features: [
                VersionHistoryFeature(
                    titleKey: "onboarding.creation.method.physical.title",
                    detailKey: "onboarding.creation.method.physical.subtitle"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.creation.passphrase.add",
                    detailKey: "onboarding.carousel.passphrase.message"
                ),
                VersionHistoryFeature(
                    titleKey: "import.recovery.word_list.title",
                    detailKey: "import.recovery.word_list.language.footer"
                ),
                VersionHistoryFeature(
                    titleKey: "onboarding.carousel.open_source.title",
                    detailKey: "onboarding.carousel.open_source.message"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.transaction.details.repeat.action",
                    detailKey: "settings.about.history.transfer_workflow.detail"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "2.40.10",
            features: [
                VersionHistoryFeature(
                    titleKey: "asset.xrp.token.rlusd.name",
                    detailKey: "settings.about.history.asset_support.detail"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.wallets.backup.passkey.section",
                    detailKey: "settings.wallets.backup.passkey.explanation"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.wallets.color.title",
                    detailKey: "settings.wallets.color.footer"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.home.assets.pinned.title",
                    detailKey: "wallet.assets.manage.footer"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.assets.add_token.action",
                    detailKey: "wallet.assets.add_token.action.hint"
                ),
                VersionHistoryFeature(
                    titleKey: "send.recipient.scan.title",
                    detailKey: "wallet.search.action.scan.subtitle"
                ),
                VersionHistoryFeature(
                    titleKey: "send.notes.add.action",
                    detailKey: "wallet.transaction.details.notes.footer"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "2.40.09",
            features: [
                VersionHistoryFeature(
                    titleKey: "settings.about.history.performance_reliability",
                    detailKey:
                        "settings.about.history.performance_reliability.detail"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "2.40.08",
            features: [
                VersionHistoryFeature(
                    titleKey: "device_migration.security.section",
                    detailKey: "device_migration.security.action.detail"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.search.start.title",
                    detailKey: "wallet.search.start.message"
                ),
                VersionHistoryFeature(
                    titleKey: "send.network_fee.title",
                    detailKey: "send.network_fee.remembered.footer"
                ),
                VersionHistoryFeature(
                    titleKey: "send.coin_control.title",
                    detailKey: "send.coin_control.option.footer"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.notifications.title",
                    detailKey: "settings.notifications.enable.detail"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "2.40.04",
            features: [
                VersionHistoryFeature(
                    titleKey: "wallet.asset.details.refresh.section",
                    detailKey: "settings.about.history.live_data.detail"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.about.history.performance_reliability",
                    detailKey:
                        "settings.about.history.performance_reliability.detail"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "2.40.03",
            features: [
                VersionHistoryFeature(
                    titleKey: "wallet.assets.add_token.action",
                    detailKey: "wallet.assets.add_token.action.hint"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.appearance.dark",
                    detailKey: "settings.appearance.dark.footer"
                ),
                VersionHistoryFeature(
                    titleKey: "import.duplicate.title",
                    detailKey: "import.duplicate.message"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.search.section.portfolio",
                    detailKey: "wallet.search.navigation.assets.subtitle"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.creation.recovery.title",
                    detailKey: "wallet.creation.recovery.message"
                )
            ]
        ),
        VersionHistoryRelease(
            version: "2.40.01",
            features: [
                VersionHistoryFeature(
                    titleKey: "onboarding.action.create",
                    detailKey: "onboarding.creation.method.quick.subtitle"
                ),
                VersionHistoryFeature(
                    titleKey: "onboarding.action.import",
                    detailKey: "import.message"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.home.action.send",
                    detailKey: "wallet.search.action.send.subtitle"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.home.action.receive",
                    detailKey: "wallet.search.action.receive.subtitle"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.wallets.backup.section",
                    detailKey: "settings.wallets.backup.footer"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.security.title",
                    detailKey: "settings.security.subtitle"
                ),
                VersionHistoryFeature(
                    titleKey: "settings.language.title",
                    detailKey: "settings.language.footer"
                ),
                VersionHistoryFeature(
                    titleKey: "wallet.assets.section.holdings",
                    detailKey: "wallet.search.navigation.assets.subtitle"
                )
            ]
        )
    ]
}

struct VersionHistoryRelease: Identifiable, Hashable {
    let version: String
    var build: String? = nil
    let features: [VersionHistoryFeature]

    var id: String { build.map { "\(version)|\($0)" } ?? version }

    var displayVersion: String {
        build.map { "\(version) (\($0))" } ?? version
    }
}

struct VersionHistoryFeature: Identifiable, Hashable {
    let titleKey: String
    let detailKey: String

    var id: String { "\(titleKey)|\(detailKey)" }
}

private struct VersionHistoryDisclosureRow: View {
    let release: VersionHistoryRelease
    let isCurrent: Bool

    @State private var isExpanded: Bool

    init(release: VersionHistoryRelease, isCurrent: Bool) {
        self.release = release
        self.isCurrent = isCurrent
        _isExpanded = State(initialValue: isCurrent)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded.hapticSelection()) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(release.features) { feature in
                    VersionHistoryFeatureRow(feature: feature)
                }
            }
            .padding(.top, 12)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: release.displayVersion)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(WalletTheme.primaryLabel)

                if isCurrent {
                    Text("settings.about.history.current")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WalletTheme.secondaryLabel)
                }
            }
        }
        .tint(WalletTheme.primaryLabel)
    }
}

private struct VersionHistoryFeatureRow: View {
    let feature: VersionHistoryFeature

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "•")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WalletTheme.secondaryLabel)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(feature.titleKey))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WalletTheme.primaryLabel)
                    .fixedSize(horizontal: false, vertical: true)

                Text(LocalizedStringKey(feature.detailKey))
                    .font(.footnote)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Version History") {
    NavigationStack {
        VersionHistorySettingsView()
    }
}
