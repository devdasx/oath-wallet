import Foundation

struct OathLanguage: RawRepresentable, CaseIterable, Identifiable, Hashable, Sendable {
    struct Definition: Hashable, Sendable {
        let code: String
        let localeIdentifier: String
        let englishName: String
        let nativeName: String
        let nameKey: String
        let flag: String
    }

    private let definition: Definition
    var rawValue: String { definition.code }
    var id: String { rawValue }
    var nativeName: String { definition.nativeName }
    var englishName: String { definition.englishName }
    var flag: String { definition.flag }
    var locale: Locale { Locale(identifier: definition.localeIdentifier) }
    var isRightToLeft: Bool {
        // Honor each supported language's declared Unicode writing script;
        // SwiftUI and UIKit still perform all layout and navigation mirroring.
        if let script = locale.language.script?.identifier,
           ["Arab", "Hebr", "Thaa", "Nkoo", "Adlm", "Rohg"].contains(script) { return true }
        return locale.language.characterDirection == .rightToLeft
    }
    fileprivate var nameKey: String { definition.nameKey }
    static let allCases = definitions.map { Self(definition: $0) }
    static let english = Self(rawValue: "en")!
    static let arabic = Self(rawValue: "ar")!

    private init(definition: Definition) { self.definition = definition }
    init?(rawValue: String) {
        guard let definition = Self.definitions.first(where: { $0.code == rawValue }) else { return nil }
        self.definition = definition
    }

    static func resolve(preferredLanguages: [String]) -> Self {
        let supported = [english.rawValue] + allCases.filter { $0 != .english }.map(\.rawValue)
        let match = Bundle.preferredLocalizations(from: supported, forPreferences: preferredLanguages).first
        return match.flatMap(Self.init(rawValue:)) ?? .english
    }

    static func matching(_ query: String, strings: OathLocalizer) -> [Self] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let matches = allCases.filter { language in
            let fields = [language.nativeName, language.englishName, strings.name(of: language), language.rawValue]
            return words.allSatisfy { word in fields.contains { field in
                field.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], locale: strings.language.locale) != nil
            } }
        }
        return matches.sorted {
            let lhs = strings.name(of: $0), rhs = strings.name(of: $1)
            let result = lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive], locale: strings.language.locale)
            return result == .orderedSame ? $0.rawValue < $1.rawValue : result == .orderedAscending
        }
    }
}

enum OathLanguagePreference: RawRepresentable, Hashable, Sendable {
    case system
    case language(OathLanguage)
    static let storageKey = "oath.languagePreference"
    static let english = Self.language(.english)
    static let arabic = Self.language(.arabic)

    var rawValue: String {
        switch self { case .system: "system"; case .language(let language): language.rawValue }
    }
    init?(rawValue: String) {
        if rawValue == "system" { self = .system }
        // The earlier generic Portuguese choice used the Brazilian locale.
        // Preserve that selection without keeping an extra language in the UI.
        else if let language = OathLanguage(rawValue: rawValue == "pt" ? "pt-BR" : rawValue) {
            self = .language(language)
        }
        else { return nil }
    }
    func resolve(preferredLanguages: [String] = Locale.preferredLanguages) -> OathLanguage {
        switch self {
        case .system: OathLanguage.resolve(preferredLanguages: preferredLanguages)
        case .language(let language): language
        }
    }
    static var current: Self {
        OathCommittedLanguage.shared.read()
    }
}

/// Explicit Apple language bundles support an in-app preference without
/// swizzling Bundle, changing system defaults, or rebuilding navigation.
struct OathLocalizer: Sendable {
    let language: OathLanguage
    let bundle: Bundle
    private let localized: Bundle
    private let english: Bundle

    init(_ language: OathLanguage, bundle: Bundle = .main) {
        self.language = language
        self.bundle = bundle
        func localizedBundle(_ code: String) -> Bundle {
            guard let path = bundle.path(forResource: code, ofType: "lproj"),
                  let localized = Bundle(path: path) else { return bundle }
            return localized
        }
        localized = localizedBundle(language.rawValue)
        english = localizedBundle("en")
    }
    static var current: Self { Self(OathLanguagePreference.current.resolve()) }

    func text(_ key: OathStringKey) -> String { string(key.rawValue, table: "Localizable") }
    func name(of language: OathLanguage) -> String {
        let value = string(language.nameKey, table: "LanguageNames")
        return value == language.nameKey ? language.englishName : value
    }
    private func string(_ key: String, table: String) -> String {
        let value = localized.localizedString(forKey: key, value: nil, table: table)
        guard value == key else { return value }
        return english.localizedString(forKey: key, value: nil, table: table)
    }
    func format(_ key: OathStringKey, _ arguments: String...) -> String {
        String(format: text(key), locale: language.locale, arguments: arguments)
    }
    func number(_ value: Int) -> String {
        value.formatted(.number.grouping(.never).locale(language.locale))
    }
    func invariant(_ value: String) -> String {
        language.isRightToLeft ? "\u{2066}\(value)\u{2069}" : value
    }
    func list(_ values: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = language.locale
        return formatter.string(from: values.map(invariant)) ?? values.joined(separator: ", ")
    }
}

/// A read-only mirror of the committed language setting for non-UI services
/// that need localized system prompts. It is never an alternate persistence store.
final class OathCommittedLanguage: @unchecked Sendable {
    static let shared = OathCommittedLanguage()
    private let lock = NSLock()
    private var value = OathLanguagePreference.system
    func read() -> OathLanguagePreference { lock.withLock { value } }
    func update(_ value: OathLanguagePreference) { lock.withLock { self.value = value } }
}
