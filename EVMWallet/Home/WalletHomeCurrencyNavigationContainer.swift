import SwiftUI
import UIKit

/// Owns the currency navigation bar independently of the Home navigation stack.
/// Native Back returns to the options state in the same resizing popover.
struct WalletHomeCurrencyNavigationContainer<Content: View>: UIViewControllerRepresentable {
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Binding var searchText: String
    let onBack: () -> Void
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(searchText: $searchText, onBack: onBack)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let coordinator = context.coordinator
        let host = UIHostingController(rootView: hostedContent)
        host.view.backgroundColor = .clear
        host.definesPresentationContext = true
        host.navigationItem.largeTitleDisplayMode = .never
        host.navigationItem.searchController = coordinator.searchController
        host.navigationItem.hidesSearchBarWhenScrolling = false
        if #available(iOS 26.0, *) {
            host.navigationItem.searchBarPlacementAllowsExternalIntegration = false
        }
        coordinator.host = host
        let navigation = UINavigationController(rootViewController: host)
        navigation.view.backgroundColor = .clear
        navigation.navigationBar.accessibilityIdentifier = "wallet-home-currency-navigation-bar"
        update(navigation, coordinator: coordinator)
        return navigation
    }

    func updateUIViewController(_ navigation: UINavigationController, context: Context) {
        context.coordinator.searchText = $searchText
        context.coordinator.onBack = onBack
        context.coordinator.host?.rootView = hostedContent
        update(navigation, coordinator: context.coordinator)
    }

    private var hostedContent: AnyView {
        AnyView(content()
            .environment(\.locale, locale)
            .environment(\.layoutDirection, layoutDirection)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .environment(\.colorScheme, colorScheme))
    }

    private func update(_ navigation: UINavigationController, coordinator: Coordinator) {
        guard let host = coordinator.host else { return }
        // A stacked search bar can consume the entire keyboard-visible
        // viewport in landscape. Keep search inside the native top bar.
        if #available(iOS 26.0, *) {
            host.navigationItem.preferredSearchBarPlacement = verticalSizeClass == .compact
                ? .integrated : .stacked
        } else {
            host.navigationItem.preferredSearchBarPlacement = verticalSizeClass == .compact
                ? .inline : .stacked
        }
        let language = Bundle.preferredLocalizations(
            from: Bundle.main.localizations, forPreferences: [locale.identifier]
        ).first
        let bundle = language.flatMap {
            Bundle.main.path(forResource: $0, ofType: "lproj")
        }.flatMap(Bundle.init(path:)) ?? .main
        host.navigationItem.title = bundle.localizedString(
            forKey: "settings.currency.title", value: nil, table: nil
        )
        host.navigationItem.leftBarButtonItem = nil
        host.navigationItem.hidesBackButton = false
        host.navigationItem.backButtonDisplayMode = .minimal
        // UIKit supplies its directional chevron; an action image would add
        // another glyph beside that native back indicator.
        let back = UIAction { [weak coordinator] _ in
            guard let coordinator else { return }
            coordinator.host?.view.endEditing(true)
            coordinator.searchController.isActive = false
            coordinator.onBack()
        }
        host.navigationItem.backAction = back
        let searchBar = coordinator.searchController.searchBar
        searchBar.placeholder = bundle.localizedString(
            forKey: "settings.currency.search", value: nil, table: nil
        )
        if searchBar.text != searchText { searchBar.text = searchText }
    }

    @MainActor
    final class Coordinator: NSObject, UISearchResultsUpdating, UISearchBarDelegate {
        var searchText: Binding<String>
        var onBack: () -> Void
        var host: UIHostingController<AnyView>?
        let searchController = UISearchController(searchResultsController: nil)

        init(searchText: Binding<String>, onBack: @escaping () -> Void) {
            self.searchText = searchText
            self.onBack = onBack
            super.init()
            searchController.obscuresBackgroundDuringPresentation = false
            searchController.hidesNavigationBarDuringPresentation = false
            searchController.searchResultsUpdater = self
            searchController.searchBar.delegate = self
            searchController.searchBar.autocorrectionType = .no
            searchController.searchBar.autocapitalizationType = .none
            searchController.searchBar.returnKeyType = .done
        }

        func updateSearchResults(for searchController: UISearchController) {
            let text = searchController.searchBar.text ?? ""
            if searchText.wrappedValue != text { searchText.wrappedValue = text }
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            searchBar.resignFirstResponder()
        }
    }
}
