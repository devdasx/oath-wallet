import OathDiagnostics
import SwiftUI
import OathDatabase

/// Import actions with disclosure arrows. The integrating flow handles the
/// chosen import route; this screen never accepts or stores a private key.
public struct OathChooseChainScreen: View {
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.colorScheme) private var colorScheme
    @State private var search = ""
    @State private var networkRecords: [NetworkRecord] = []
    @State private var loading = true
    @State private var failed = false
    private let onChoose: (OathPrivateKeyChoice) -> Void

    public init(onChoose: @escaping (OathPrivateKeyChoice) -> Void) {
        self.onChoose = onChoose
    }

    private var matches: [OathPrivateKeyChoice] {
        let available = networkRecords.compactMap { OathImportChain(rawValue: $0.id) }
        let choices = OathPrivateKeyChoice.matching("", localizedEVMTitle: strings.text(.evmTitle), availableNetworks: available)
        let aliases = Set(OathPrivateKeyChoice.matching(search, localizedEVMTitle: strings.text(.evmTitle), availableNetworks: available).map(\.id))
        let ranks = Dictionary(uniqueKeysWithValues: networkRecords.enumerated().map { ($0.element.id, $0.offset) })
        return choices.compactMap { choice -> OathPrivateKeyChoice? in
            let records = networkRecords.filter { record in choice.networks.contains { $0.id == record.id } }
            guard aliases.contains(choice.id) || records.contains(where: { ($0.name + " " + $0.symbol).localizedStandardContains(search) }) else { return nil }
            return OathPrivateKeyChoice(id: choice.id, title: choice.isEVM ? strings.text(.evmTitle) : records.first?.name ?? choice.title,
                                       networks: choice.networks)
        }.sorted {
            // The EVM choice represents several networks; place it at the rank
            // of its highest-valued native holding instead of pinning it first.
            let lhs = $0.networks.compactMap { ranks[$0.id] }.min() ?? Int.max
            let rhs = $1.networks.compactMap { ranks[$0.id] }.min() ?? Int.max
            return lhs == rhs
                ? AssetSortKey(name: $0.title, identity: $0.id) < AssetSortKey(name: $1.title, identity: $1.id)
                : lhs < rhs
        }
    }
    private var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.36, green: 0.56, blue: 1)
            : Color(red: 0.12, green: 0.30, blue: 0.90)
    }

    public var body: some View {
        List {
            if !matches.isEmpty {
                Section {
                    ForEach(matches) { choice in
                        choiceButton(choice, identifier: "import.choice.\(choice.id)")
                    }
                } header: {
                    Text(strings.text(.chains)).oathFont(.footnote)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: OathSurfaceColors.canvas))
        .toolbarBackground(Color(uiColor: OathSurfaceColors.canvas), for: .navigationBar)
        .navigationTitle(strings.text(.chooseChain))
        .oathNativeLocalization()
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(strings.text(.searchChains)))
        .overlay {
            if loading { ProgressView() }
            else if failed {
                OathEmptyStateScrollView {
                    OathEmptyState(title: strings.text(.walletUnavailable), systemImage: "externaldrive.badge.exclamationmark") {
                        OathActionButton(title: strings.text(.tryAgain), appearance: .secondary) { Task { await loadNetworks() } }
                            .oathActionArea()
                    }
                }
            } else if matches.isEmpty {
                OathEmptyStateScrollView {
                    OathEmptyState(strings.text(.noSearchResults), systemImage: "magnifyingglass",
                                   description: strings.format(.noSearchResultsDetail, search))
                }
            }
        }
        .tint(accent)
        .task { await loadNetworks() }
        .accessibilityIdentifier("import.chooseChain")
    }

    private func loadNetworks() async {
        loading = true; failed = false
        defer { loading = false }
        do {
            let database = try await OathDataEnvironment.shared.database()
            networkRecords = try await database.networks()
        } catch { OathDiagnostics.record(error); failed = true }
    }

    private func choiceButton(_ choice: OathPrivateKeyChoice, identifier: String) -> some View {
        OathButton { onChoose(choice) } label: {
            OathSettingsRow(title: choice.isEVM ? strings.text(.evmTitle) : strings.invariant(choice.title),
                icon: "network", subtitle: choice.isEVM ? strings.format(.evmAccessibility,
                    strings.list(choice.logoPreviewNetworks.map(\.name))) : nil,
                networkLogo: choice.networks.first.flatMap { chain in networkRecords.first { $0.id == chain.id }?.logo })
        }
        .buttonStyle(OathSettingsRowButtonStyle())
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(choice.isEVM ? strings.text(.evmTitle) : choice.title)
        .accessibilityHint(choice.isEVM
            ? strings.format(.evmAccessibility, strings.list(choice.networks.compactMap { chain in networkRecords.first { $0.id == chain.id }?.name }))
            : strings.text(.chainAccessibility))
        .accessibilityIdentifier(identifier)
    }
}
