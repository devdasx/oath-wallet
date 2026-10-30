import SwiftUI
import OathDiagnostics

struct OathHelpCenterPage: View {
    @Environment(\.oathLocalizer) private var strings
    @State private var query = ""
    @State private var catalog: OathHelpArticleCatalog?
    @State private var sections: [OathHelpArticleCatalog.Section] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var retry = 0
    @State private var catalogRevision = 0

    private struct Load: Equatable { let retry: Int; let language: String }
    private struct Search: Equatable { let query: String; let language: String?; let revision: Int }

    var body: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.articles) { article in
                        Link(destination: article.url) {
                            OathSettingsRow(title: article.title, icon: "doc.text", subtitle: article.summary)
                        }
                        .buttonStyle(OathSettingsRowButtonStyle())
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("help.article.\(article.id)")
                    }
                } header: {
                    Text(section.category.title)
                        .oathFont(.subheadline, weight: .semibold)
                        .foregroundStyle(.secondary).textCase(nil)
                        .padding(.vertical, 12)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .id(strings.language.rawValue)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .frame(maxWidth: 700).frame(maxWidth: .infinity)
        .overlay {
            if failed {
                OathEmptyStateScrollView {
                    OathEmptyState(title: strings.text(.helpCenter), systemImage: "doc.text.magnifyingglass", isError: true) {
                        OathButton(strings.text(.tryAgain)) { retry += 1 }
                        Link(strings.text(.helpCenter), destination: OathSupportLinks.help)
                    }
                }
            } else if loaded && sections.isEmpty {
                OathEmptyStateScrollView {
                    OathEmptyState(strings.text(.noSearchResults), systemImage: "magnifyingglass")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(strings.text(.searchTitle)))
        .task(id: Load(retry: retry, language: strings.language.rawValue)) {
            catalog = nil
            sections = []
            loaded = false
            failed = false
            let language = strings.language.rawValue
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let loadedCatalog = try await OathHelpCatalogStore.shared.load(language: language)
                    try Task.checkCancellation()
                    catalog = loadedCatalog
                    catalogRevision += 1
                    failed = false
                } catch is CancellationError { /* Page dismissed during shared catalog loading. */ }
                catch {
                    guard !Task.isCancelled else { return }
                    OathDiagnostics.record(error, component: "help_center", operation: "load_catalog")
                    failed = true
                    loaded = true
                }
            }
        }
        .task(id: Search(query: query, language: catalog?.language, revision: catalogRevision)) {
            guard let catalog else { return }
            let search = query
            let result = await Task.detached(priority: .userInitiated) { catalog.sections(matching: search) }.value
            // Search misses/cancellation are expected. Never log a query, or
            // allow a slow older search to overwrite the latest results.
            guard !Task.isCancelled else { return }
            sections = result
            loaded = true
        }
        .accessibilityIdentifier("settings.help.articles")
    }
}
