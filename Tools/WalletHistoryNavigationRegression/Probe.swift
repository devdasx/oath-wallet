import SwiftUI

private enum OathHomeTab: Hashable { case wallet, history, search }
private struct Profile { let id: UUID; var revision = 0 }
private struct Session { let balancesHidden = false }
private struct OathHistoryFilterSelection {}
private struct Entry { let networkID = "ethereum"; let wallet: String }
private struct Holding {}
private struct Item: Identifiable { let id = "shared-transaction"; let entry: Entry; let holding = Holding() }
private struct Model { let items: [Item]; let displayCurrency = "USD" }
private enum OathImportChain: String { case ethereum; var name: String { "Ethereum" } }
private enum Wallets {
    static let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static func name(_ id: String) -> String { id == first.uuidString ? "Wallet 1" : "Wallet 2" }
}

private struct OathTransactionDetailScreen: View {
    let entry: Entry
    let holding: Holding
    let networkName: String
    let currency: String
    let balancesHidden: Bool
    var body: some View {
        Text(entry.wallet + " receipt").accessibilityIdentifier("receipt")
            .navigationTitle("Transaction details")
    }
}

private struct OathChainActivityScreen: View {
    let walletID: String
    let session: Session
    let query: String
    let isVisible: Bool
    let filterSelection: Binding<OathHistoryFilterSelection>
    @State private var selected: Item?
    private var model: Model { .init(items: [.init(entry: .init(wallet: Wallets.name(walletID)))]) }

    var body: some View {
        List {
            Text(Wallets.name(walletID) + " history").accessibilityIdentifier("history.wallet")
            Button("Received USDC") { selected = model.items[0] }
                .accessibilityIdentifier("transaction.row")
        }
        .navigationTitle("History")
        // PRODUCTION_DESTINATION
    }
}

private struct OathHomeSearchField: ViewModifier {
    @Binding var query: String
    @Binding var isPresented: Bool
    let prompt: String
    func body(content: Content) -> some View { content }
}
private struct OathEmptyStateScrollView<Header: View, Content: View>: View {
    let centersContent: Bool
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content
    var body: some View { ScrollView { header(); content() } }
}
private enum OathSurfaceColors { static var groupedCanvas: UIColor { .systemBackground } }
private struct Strings { enum Key { case assets }; func text(_ key: Key) -> String { "Assets" } }
private struct Portfolio { let searchRows: [Int] = [] }
private struct TokenSearch { let results: [Int] = [] }
private extension View {
    func oathFont(_ font: Font, weight: Font.Weight) -> some View { self.font(font.weight(weight)) }
    func oathNativeLocalization() -> some View { self }
}

private struct Probe: View {
    @State private var profile: Profile? = .init(id: Wallets.first)
    @State private var selectedTab = OathHomeTab.wallet
    @State private var searchContext = OathHomeTab.wallet
    @State private var historyQuery = ""
    @State private var historyFilters = OathHistoryFilterSelection()
    @State private var searchPresented = false
    private let session = Session()
    private let strings = Strings()
    private let portfolioPresentation = Portfolio()
    private let tokenSearch = TokenSearch()
    private let searchPrompt = "Search"
    private var searchBinding: Binding<String> { $historyQuery }
    private func assetList(searching: Bool) -> some View { Text("Assets") }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Wallet", systemImage: "wallet.bifold", value: OathHomeTab.wallet) {
                NavigationStack {
                    List {
                        Text(Wallets.name(profile!.id.uuidString)).accessibilityIdentifier("active.wallet")
                        Button("Switch wallet") {
                            profile = .init(id: profile?.id == Wallets.first ? Wallets.second : Wallets.first)
                        }.accessibilityIdentifier("switch.wallet")
                        Button("Refresh same wallet") {
                            profile?.revision += 1
                        }.accessibilityIdentifier("refresh.wallet")
                    }.navigationTitle("Wallet")
                }
            }
            Tab("History", systemImage: "clock", value: OathHomeTab.history) { historyNavigation }
            Tab("Search", systemImage: "magnifyingglass", value: OathHomeTab.search, role: .search) { searchNavigation }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab != .search { searchPresented = false; searchContext = tab }
        }
    }

    // PRODUCTION_NAVIGATION
}

@main struct WalletHistoryNavigationProbe: App {
    var body: some Scene { WindowGroup { Probe() } }
}
