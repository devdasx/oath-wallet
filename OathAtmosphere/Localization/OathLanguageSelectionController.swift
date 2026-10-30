import SwiftUI
import UIKit

@MainActor struct OathLanguageSheetConfiguration {
    enum Style { case sheet, settings }
    let strings: OathLocalizer
    let preference: OathLanguagePreference
    let onChoose: (OathLanguagePreference) -> Void
    let onBack: () -> Void
    let onClose: () -> Void
    var style: Style = .settings
}

/// The sheet owns this navigation controller as a child. Search belongs to its
/// top navigation item, never a bottom toolbar or another modal presentation.
final class OathLanguageSelectionController: UINavigationController, OathSheetNativeMeasuring {
    private let languages: LanguageListController
    var onContentSizeChange: (() -> Void)?
    private var lastReportedHeight: CGFloat = 0

    init(configuration: OathLanguageSheetConfiguration) {
        languages = LanguageListController(configuration: configuration)
        super.init(rootViewController: languages)
        languages.onLayout = { [weak self] in self?.reportHeight() }
        isToolbarHidden = true
        update(configuration: configuration)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    var fittingContentHeight: CGFloat { languages.fittingContentHeight }

    func update(configuration: OathLanguageSheetConfiguration) {
        OathLayoutDirection.apply(configuration.strings.language, to: self)
        languages.update(configuration: configuration)
        OathSheetNavigationControls.configure(navigationBar, strings: configuration.strings)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        reportHeight()
    }
    private func reportHeight() {
        let height = fittingContentHeight
        guard height.isFinite, abs(height - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = height
        onContentSizeChange?()
    }
}

/// Settings already owns a NavigationStack. Embed only the native table here,
/// so Language participates in that stack instead of adding a second navigator.
struct OathLanguageSettingsPage: UIViewControllerRepresentable {
    let configuration: OathLanguageSheetConfiguration

    func makeUIViewController(context: Context) -> UIViewController {
        LanguageListController(configuration: configuration, usesParentNavigationItem: true)
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        (controller as? LanguageListController)?.update(configuration: configuration)
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: ()) {
        (controller as? LanguageListController)?.leaveNavigationStack()
    }
}

private final class LanguageListController: UITableViewController, UISearchResultsUpdating, UISearchControllerDelegate {
    private var configuration: OathLanguageSheetConfiguration
    private let usesParentNavigationItem: Bool
    private weak var searchOwner: UIViewController?
    private var pendingSelection: OathLanguagePreference?
    private let search = UISearchController(searchResultsController: nil)
    private var languages: [OathLanguage] = []
    private var emptyStateHost: UIHostingController<AnyView>?
    private var unfilteredContentHeight: CGFloat = 0
    var onLayout: (() -> Void)?

    init(configuration: OathLanguageSheetConfiguration, usesParentNavigationItem: Bool = false) {
        self.configuration = configuration
        self.usesParentNavigationItem = usesParentNavigationItem
        super.init(style: configuration.style == .settings ? .plain : .insetGrouped)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private var query: String { search.searchBar.text ?? "" }
    private var showsDeviceLanguage: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var fittingContentHeight: CGFloat {
        guard isViewLoaded else { return 0 }
        // Keep the measured full-list extent while filtering so the keyboard
        // and focused search field do not jump as results change. iOS caps it.
        return max(unfilteredContentHeight, tableView.contentSize.height) + tableView.adjustedContentInset.top
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The expanded sheet is opaque. Use native grouped surface roles so
        // its cards remain distinct from the canvas in both appearances.
        tableView.backgroundColor = configuration.style == .settings ? OathSurfaceColors.canvas : OathSurfaceColors.sheet
        tableView.separatorStyle = .none
        if configuration.style == .settings {
            tableView.sectionHeaderTopPadding = 0
        }
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = UITableView.automaticDimension
        tableView.keyboardDismissMode = .interactive
        tableView.accessibilityIdentifier = "settings.languageList"
        search.searchResultsUpdater = self
        search.delegate = self
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        search.automaticallyShowsCancelButton = false
        search.searchBar.autocapitalizationType = .none
        search.searchBar.autocorrectionType = .no
        search.searchBar.searchTextField.accessibilityIdentifier = "settings.languageSearch"
        search.searchBar.accessibilityIdentifier = "settings.languageSearch"
        attachSearch()
        applyConfiguration()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent != nil { attachSearch() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        attachSearch()
    }

    private func attachSearch() {
        var owner: UIViewController = self
        if usesParentNavigationItem {
            // UINavigationController displays the item of its direct child.
            // A representable is contained by that SwiftUI hosting controller;
            // configuring the table's own item would leave Search invisible.
            guard let navigation = navigationController else { return }
            while owner.parent !== navigation {
                guard let parent = owner.parent else { return }
                owner = parent
            }
        }
        guard searchOwner !== owner || owner.navigationItem.searchController !== search else { return }
        detachSearch()
        searchOwner = owner
        let item = owner.navigationItem
        item.searchController = search
        item.preferredSearchBarPlacement = .stacked
        item.hidesSearchBarWhenScrolling = false
        item.largeTitleDisplayMode = .never
        if #available(iOS 26.0, *) {
            item.searchBarPlacementAllowsToolbarIntegration = false
            item.searchBarPlacementAllowsExternalIntegration = false
        }
        owner.definesPresentationContext = true
    }

    func detachSearch() {
        if let owner = searchOwner, owner.navigationItem.searchController === search {
            owner.navigationItem.searchController = nil
        }
        searchOwner = nil
    }

    func leaveNavigationStack() {
        pendingSelection = nil
        detachSearch()
    }

    func didDismissSearchController(_ searchController: UISearchController) {
        guard let preference = pendingSelection else { return }
        pendingSelection = nil
        configuration.onChoose(preference)
    }

    func update(configuration: OathLanguageSheetConfiguration) {
        let changed = self.configuration.strings.language != configuration.strings.language
            || self.configuration.preference != configuration.preference
        self.configuration = configuration
        loadViewIfNeeded()
        attachSearch()
        if changed { applyConfiguration() }
    }

    private func applyConfiguration() {
        let strings = configuration.strings
        OathLayoutDirection.apply(strings.language, to: self)
        OathLayoutDirection.apply(strings.language, to: tableView)
        OathLayoutDirection.apply(strings.language, to: search)
        OathLayoutDirection.apply(strings.language, to: search.searchBar)
        OathLayoutDirection.apply(strings.language, to: search.searchBar.searchTextField)
        search.searchBar.placeholder = strings.text(.searchLanguages)
        OathKeyboardAccessory.removeFromSearch(search.searchBar.searchTextField)
        search.searchBar.searchTextField.font = strings.language == .arabic
            ? OathArabicFont.regular.uiFont(size: 17, relativeTo: .body)
            : .preferredFont(forTextStyle: .body)
        if !usesParentNavigationItem {
            title = strings.text(.language)
            navigationItem.leftBarButtonItem = OathSheetNavigationControls.back(strings: strings, identifier: "language.back") { [weak self] in
                guard let self else { return }
                self.search.isActive = false
                self.configuration.onBack()
            }
            navigationItem.rightBarButtonItem = OathSheetNavigationControls.close(strings: strings) { [weak self] in
                guard let self else { return }
                self.search.isActive = false
                self.configuration.onClose()
            }
        }
        refreshResults()
    }

    func updateSearchResults(for searchController: UISearchController) { refreshResults() }

    private func refreshResults() {
        languages = OathLanguage.matching(query, strings: configuration.strings)
        tableView.reloadData()
        if languages.isEmpty {
            let strings = configuration.strings
            let detail = strings.format(.noLanguageResultsDetail, query)
            let root = AnyView(OathEmptyStateScrollView {
                OathEmptyState(strings.text(.noSearchResults), systemImage: "magnifyingglass",
                               description: detail)
            }.oathLanguage(strings.language))
            if let emptyStateHost {
                emptyStateHost.rootView = root
            } else {
                let host = UIHostingController(rootView: root)
                addChild(host)
                host.view.backgroundColor = .clear
                tableView.backgroundView = host.view
                host.didMove(toParent: self)
                emptyStateHost = host
            }
        } else if let host = emptyStateHost {
            host.willMove(toParent: nil)
            tableView.backgroundView = nil
            host.removeFromParent()
            emptyStateHost = nil
        }
        onLayout?()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if showsDeviceLanguage { unfilteredContentHeight = tableView.contentSize.height }
        onLayout?()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { showsDeviceLanguage ? 2 : 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        showsDeviceLanguage && section == 0 ? 1 : languages.count
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = (tableView.dequeueReusableCell(withIdentifier: "language") as? OathLanguageCell)
            ?? OathLanguageCell(style: .default, reuseIdentifier: "language")
        let settingsStyle = configuration.style == .settings
        cell.showsSeparator = !settingsStyle && indexPath.row < tableView.numberOfRows(inSection: indexPath.section) - 1
        var background = settingsStyle ? UIBackgroundConfiguration.listPlainCell() : .listGroupedCell()
        background.backgroundColor = settingsStyle ? OathSurfaceColors.canvas : OathSurfaceColors.sheetCard
        cell.backgroundConfiguration = background
        let strings = configuration.strings
        OathLayoutDirection.apply(strings.language, to: cell)
        let isSystem = showsDeviceLanguage && indexPath.section == 0
        let language = isSystem ? OathLanguage.resolve(preferredLanguages: Locale.preferredLanguages) : languages[indexPath.row]
        let preference: OathLanguagePreference = isSystem ? .system : .language(language)
        cell.accessoryType = configuration.preference == preference ? .checkmark : .none
        cell.tintColor = UIColor(OathOnboardingColors.blue)
        if configuration.preference == preference { cell.accessibilityTraits.insert(.selected) }
        else { cell.accessibilityTraits.remove(.selected) }
        cell.accessibilityIdentifier = isSystem ? "language.choice.system" : "language.choice.\(language.rawValue)"
        cell.contentConfiguration = UIHostingConfiguration {
            LanguageRow(language: language, strings: strings, isSystem: isSystem, settingsStyle: settingsStyle)
                .oathLanguage(strings.language)
        }
        // Remove the hosting wrapper's extra vertical space. Keep native
        // automatic row sizing, including growth for wrapped or larger text.
        .margins(.vertical, 0)
        return cell
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard configuration.style == .settings else { return UITableView.automaticDimension }
        return section == 0 ? 12 : 24 + OathHairlineMetrics.thickness(displayScale: traitCollection.displayScale)
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard configuration.style == .settings else { return nil }
        if section > 0 {
            return UIHostingConfiguration { OathSettingsSectionRule() }
                .margins(.all, 0).makeContentView()
        }
        let header = UIView()
        header.backgroundColor = OathSurfaceColors.canvas
        return header
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        OathHaptics.shared.play(.selection)
        let preference: OathLanguagePreference = showsDeviceLanguage && indexPath.section == 0
            ? .system : .language(languages[indexPath.row])
        if usesParentNavigationItem, search.isActive {
            // Search has its own native presentation. Finish its dismissal
            // before popping the page; overlapping both transitions can leave
            // UIKit displaying Language after SwiftUI already popped its path.
            pendingSelection = preference
            search.isActive = false
            return
        }
        search.isActive = false
        view.endEditing(true)
        configuration.onChoose(preference)
    }
}

/// UIKit's built-in table separator has a fixed thickness. Use the same
/// two-pixel rule as SwiftUI while keeping the native cells and selection.
private final class OathLanguageCell: UITableViewCell {
    private let rule = UIView()
    var showsSeparator = false { didSet { rule.isHidden = !showsSeparator } }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        rule.backgroundColor = .separator
        rule.isUserInteractionEnabled = false
        rule.isHidden = true
        addSubview(rule)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = OathHairlineMetrics.thickness(displayScale: traitCollection.displayScale)
        let leading = effectiveUserInterfaceLayoutDirection == .rightToLeft ? CGFloat.zero : layoutMargins.left
        let trailing = effectiveUserInterfaceLayoutDirection == .rightToLeft ? layoutMargins.right : CGFloat.zero
        rule.frame = CGRect(x: leading, y: bounds.height - height,
                            width: max(0, bounds.width - leading - trailing), height: height)
        bringSubviewToFront(rule)
    }
}

private struct LanguageRow: View {
    let language: OathLanguage
    let strings: OathLocalizer
    let isSystem: Bool
    var settingsStyle = false
    @ScaledMetric(relativeTo: .body) private var tileSize = 38.0

    var body: some View {
        HStack(spacing: settingsStyle ? 16 : 12) {
            if settingsStyle {
                if isSystem {
                    OathSettingsIcon(symbol: "globe")
                } else {
                    Text(verbatim: language.flag)
                        .font(.title2)
                        .frame(width: tileSize, height: tileSize)
                        .background(Color(uiColor: OathSurfaceColors.field), in: .rect(cornerRadius: tileSize * 0.28))
                        .accessibilityHidden(true)
                }
            } else {
                Group {
                    if isSystem { Image(systemName: "globe").foregroundStyle(.secondary) }
                    else { Text(verbatim: language.flag) }
                }
                .font(.title2)
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                if isSystem {
                    Text(strings.text(.systemLanguage)).oathFont(.body)
                    Text(strings.name(of: language)).oathFont(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text(verbatim: language.nativeName)
                        .oathFont(.body)
                        .environment(\.oathLanguage, language)
                        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
                    if strings.name(of: language) != language.nativeName {
                        Text(strings.name(of: language)).oathFont(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, settingsStyle ? 17 : 0)
        .accessibilityElement(children: .combine)
    }
}
