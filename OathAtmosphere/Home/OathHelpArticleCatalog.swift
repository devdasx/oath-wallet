import Foundation

/// Published editorial content only. The catalog never reads wallet data or
/// sends search queries to a server; article links use the existing browser.
struct OathHelpArticleCatalog: Sendable {
    struct Category: Decodable, Identifiable, Sendable {
        let id: String
        let title: String
    }

    struct Article: Decodable, Identifiable, Sendable {
        let id: String
        let categoryID: String
        let title: String
        let summary: String
        let body: String

        // IDs are validated at the catalog boundary. Content cannot supply an
        // external destination, tracking query, custom scheme or credential.
        var url: URL { URL(string: "https://help.oathwallet.org/articles/" + id)! }
    }

    struct Section: Identifiable, Sendable {
        let category: Category
        let articles: [Article]
        var id: String { category.id }
    }

    enum CatalogError: Error { case missingResource, invalidCatalog, invalidTranslations }
    private struct Document: Decodable {
        let version: Int
        let categories: [Category]
        let articles: [Article]
    }
    private struct IndexedArticle: Sendable {
        let article: Article
        let title: String
        let originalTitle: String
        let summary: String
        let category: String
        let content: String
        let compactContent: String
    }
    private struct Translations: Decodable {
        let version: Int
        let source: [String: String]
        let localizations: [String: [String: String]]
    }
    let language: String
    let categories: [Category]
    let articles: [Article]
    private let index: [IndexedArticle]

    init(data: Data, translationsData: Data? = nil, language: String = "en") throws {
        guard data.count <= 8_000_000 else { throw CatalogError.invalidCatalog }
        let document = try JSONDecoder().decode(Document.self, from: data)
        let categoryIDs = Set(document.categories.map(\.id))
        guard document.version == 1, (1...50).contains(document.categories.count),
              (1...2_000).contains(document.articles.count), categoryIDs.count == document.categories.count,
              Set(document.articles.map(\.id)).count == document.articles.count,
              document.categories.allSatisfy({ Self.validID($0.id) && !$0.title.isEmpty && $0.title.count <= 200 }),
              document.articles.allSatisfy({ Self.validID($0.id) && categoryIDs.contains($0.categoryID)
                  && !$0.title.isEmpty && $0.title.count <= 300 && !$0.summary.isEmpty && $0.summary.count <= 2_000
                  && !$0.body.isEmpty && $0.body.count <= 80_000 }) else { throw CatalogError.invalidCatalog }
        self.language = language
        var source = Dictionary(uniqueKeysWithValues: document.categories.map { ("category." + $0.id, $0.title) })
        for article in document.articles {
            source["article." + article.id + ".title"] = article.title
            source["article." + article.id + ".summary"] = article.summary
        }
        let text: [String: String]
        if language == "en" { text = source }
        else {
            guard let translationsData, translationsData.count <= 8_000_000 else { throw CatalogError.invalidTranslations }
            let translations = try JSONDecoder().decode(Translations.self, from: translationsData)
            guard translations.version == 1, translations.source == source,
                  let localized = translations.localizations[language], Set(localized.keys) == Set(source.keys),
                  localized.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 4_000 })
            else { throw CatalogError.invalidTranslations }
            text = localized
        }
        categories = document.categories.map { Category(id: $0.id, title: text["category." + $0.id]!) }
        articles = document.articles.map {
            Article(id: $0.id, categoryID: $0.categoryID, title: text["article." + $0.id + ".title"]!,
                    summary: text["article." + $0.id + ".summary"]!, body: $0.body)
        }
        let categoryNames = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.title) })
        index = zip(articles, document.articles).map { article, original in
            let title = Self.normalize(article.title)
            let originalTitle = Self.normalize(original.title)
            let summary = Self.normalize(article.summary + " " + original.summary)
            let category = Self.normalize((categoryNames[article.categoryID] ?? "") + " " + (source["category." + article.categoryID] ?? ""))
            // Search both the displayed language and published English. Bodies
            // and canonical links stay untouched; no query leaves the device.
            let content = [title, originalTitle, summary, category, Self.normalize(article.body)].joined(separator: " ")
            return IndexedArticle(article: article, title: title, originalTitle: originalTitle, summary: summary, category: category,
                                  content: content, compactContent: content.replacingOccurrences(of: " ", with: ""))
        }
    }

    func sections(matching query: String) -> [Section] {
        let normalized = Self.normalize(String(query.prefix(512)))
        let words = normalized.split(separator: " ").map(String.init)
        // Natural questions should find the topic, even when their connecting
        // words do not occur verbatim in an article. Punctuation is irrelevant.
        let connective: Set<String> = ["how", "do", "i", "the", "a", "an", "to", "my", "in", "on", "can", "is", "of", "and", "for", "with"]
        let keywords = words.filter { !connective.contains($0) }
        let terms = keywords.isEmpty ? words : keywords
        let ranked = index.enumerated().compactMap { offset, entry -> (offset: Int, score: Int, article: Article)? in
            guard terms.allSatisfy({ entry.content.contains($0) || entry.compactContent.contains($0) }) else { return nil }
            var score = entry.title == normalized || entry.originalTitle == normalized ? 1_000 : 0
            if !normalized.isEmpty, entry.title.contains(normalized) || entry.originalTitle.contains(normalized) { score += 200 }
            for term in terms {
                if entry.title.contains(term) || entry.originalTitle.contains(term) { score += 40 }
                if entry.summary.contains(term) { score += 12 }
                if entry.category.contains(term) { score += 8 }
            }
            return (offset, score, entry.article)
        }.sorted { $0.score == $1.score ? $0.offset < $1.offset : $0.score > $1.score }
        let grouped = Dictionary(grouping: ranked, by: { $0.article.categoryID })
        // Browsing retains the website's collection order. Search puts the
        // section with the strongest match first, then ranks its article rows.
        let ordered = categories.enumerated().sorted {
            let lhs = grouped[$0.element.id]?.first?.score ?? -1
            let rhs = grouped[$1.element.id]?.first?.score ?? -1
            return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
        }
        return ordered.compactMap { _, category in
            guard let values = grouped[category.id], !values.isEmpty else { return nil }
            return Section(category: category, articles: values.map(\.article))
        }
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 160 && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Share one immutable, pre-indexed catalog across presentations. Disk reading
/// and normalization happen off the UI actor. A failed load can be retried.
actor OathHelpCatalogStore {
    static let shared = OathHelpCatalogStore(
        resource: Bundle.main.url(forResource: "HelpCenterArticles", withExtension: "json"),
        translationsResource: Bundle.main.url(forResource: "HelpCenterTranslations", withExtension: "json"))
    private let resource: URL?
    private let translationsResource: URL?
    private var cached: [String: OathHelpArticleCatalog] = [:]
    private var pending: [String: Task<OathHelpArticleCatalog, Error>] = [:]

    init(resource: URL?, translationsResource: URL? = nil) {
        self.resource = resource
        self.translationsResource = translationsResource
    }

    func load(language: String = "en") async throws -> OathHelpArticleCatalog {
        if let cached = cached[language] { return cached }
        if let pending = pending[language] { return try await pending.value }
        guard let resource else { throw OathHelpArticleCatalog.CatalogError.missingResource }
        let translationsResource = translationsResource
        let task = Task.detached(priority: .userInitiated) {
            let translations = language == "en" ? nil : try translationsResource.map { try Data(contentsOf: $0) }
            return try OathHelpArticleCatalog(data: Data(contentsOf: resource), translationsData: translations, language: language)
        }
        pending[language] = task
        defer { pending[language] = nil }
        let result = try await task.value
        // Bound retained indexes when languages change repeatedly. Running
        // searches hold their own immutable value and remain safe to complete.
        if cached.count >= 3 { cached.removeAll() }
        cached[language] = result
        return result
    }
}
