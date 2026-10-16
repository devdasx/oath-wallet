import SwiftUI

// Isolated native-search reproduction: no vault, network, telemetry, or real
// wallet data. Uses the app's production search modifiers and navigation chrome.
@main struct SearchFixtureApp: App {
    var body: some Scene { WindowGroup { Fixture() } }
}

private struct Fixture: View {
    @State private var tab = OathHomeTab.wallet
    @State private var context = OathHomeTab.wallet
    @State private var assetQuery = ""
    @State private var historyQuery = ""
    @State private var searchPresented = false
    @State private var assetPath: [Int] = []
    private var query: Binding<String> { context == .history ? $historyQuery : $assetQuery }
    private var prompt: String { context == .history ? "Search transactions" : "Search assets or contract address" }

    var body: some View {
        tabs.modifier(OathSearchTabActivation())
        .onChange(of: tab) { _, value in
            if value != .search { searchPresented = false; context = value }
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab(value: .wallet) {
                NavigationStack(path: $assetPath) { content(title: "Wallet", query: "") }
            } label: { Image(systemName: "wallet.bifold") }
            .accessibilityLabel("Wallet")
            Tab(value: .history) {
                NavigationStack { content(title: "History", query: "") }
            } label: { Image(systemName: "clock.arrow.circlepath") }
            .accessibilityLabel("History")
            Tab(value: .search, role: .search) {
                searchNavigation.modifier(OathHomeSearchField(query: query, isPresented: $searchPresented, prompt: prompt))
            } label: { Image(systemName: "magnifyingglass") }
            .accessibilityLabel("Search")
        }
    }

    private var searchNavigation: some View {
        NavigationStack { content(title: context == .history ? "History" : "Assets", query: query.wrappedValue,
                                  selectingAsset: context == .wallet) }
    }

    private func content(title: String, query: String, selectingAsset: Bool = false) -> some View {
        ScrollView {
            LazyVStack {
                ForEach((0..<100).filter { query.isEmpty || "Token \($0)".contains(query) }, id: \.self) { index in
                    if selectingAsset {
                        Button {
                            searchPresented = false
                            assetQuery = ""
                            assetPath = [index]
                            tab = .wallet
                        } label: { Text("Token \(index)").frame(maxWidth: .infinity, minHeight: 60) }
                    } else {
                        NavigationLink(value: index) { Text("Token \(index)").frame(maxWidth: .infinity, minHeight: 60) }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .oathNativeLocalization()
        .navigationDestination(for: Int.self) { index in
            Text("Details \(index)")
                .toolbar(.hidden, for: .tabBar)
                .oathNativeLocalization()
        }
    }
}

// Minimal localization dependencies for the production navigation modifier.
enum OathLanguage { case english, arabic }
enum OathStringKey { case back }
struct OathLocalizer {
    init(_ language: OathLanguage) {}
    func text(_ key: OathStringKey) -> String { "Back" }
}
private struct LanguageKey: EnvironmentKey { static let defaultValue = OathLanguage.english }
extension EnvironmentValues {
    var oathLanguage: OathLanguage {
        get { self[LanguageKey.self] }
        set { self[LanguageKey.self] = newValue }
    }
}
@MainActor enum OathLayoutDirection {
    static func apply(_ language: OathLanguage, to controller: UIViewController) {
        controller.traitOverrides.layoutDirection = language == .arabic ? .rightToLeft : .leftToRight
        apply(language, to: controller.view)
    }
    static func apply(_ language: OathLanguage, to view: UIView) {
        view.traitOverrides.layoutDirection = language == .arabic ? .rightToLeft : .leftToRight
        view.semanticContentAttribute = language == .arabic ? .forceRightToLeft : .forceLeftToRight
    }
}
@MainActor enum OathKeyboardAccessory {
    static func removeFromSearch(_ field: UISearchTextField) {}
}
