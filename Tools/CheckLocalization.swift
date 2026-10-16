import Foundation
import CoreText

@main struct CheckLocalization {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ reason: String) {
            precondition(condition(), reason)
            checks += 1
        }
        func hasLeftToRightGroup(_ value: String, body: String) -> Bool {
            var depth = 0
            var content = ""
            for character in value {
                switch character {
                case "\u{2066}", "\u{2067}", "\u{2068}":
                    if depth > 0 { depth += 1 }
                    else if character == "\u{2066}" { depth = 1; content = "" }
                case "\u{2069}":
                    if depth > 0 {
                        depth -= 1
                        if depth == 0 && content == body { return true }
                    }
                default:
                    if depth > 0 { content.append(character) }
                }
            }
            return false
        }
        // String(format:locale:) can add an FSI/PDI around each %@ argument.
        // Those nested isolates must not invalidate the surrounding LTR group.
        check(hasLeftToRightGroup("\u{2066}+\u{2068}9\u{2069}\u{2069}", body: "+9"), "Nested system isolation is valid")
        check(!hasLeftToRightGroup("\u{2066}+\u{2069}\u{2068}9\u{2069}", body: "+9"), "Separately isolated plus and count must fail")
        precondition(CommandLine.arguments.count == 3, "Usage: CheckLocalization <app-bundle> <expected-build>")
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let bundle = Bundle(url: url)!
        check(bundle.infoDictionary?["CFBundleVersion"] as? String == CommandLine.arguments[2], "Build version must stay correct with a generated Info.plist")
        let languages = OathLanguage.allCases
        // Product scope: the existing Oath app's WalletAppLanguage.supportedIdentifiers.
        // Keep this independent of the generated registry so accidental additions fail.
        let approved = Set([
            "en", "zh-Hans", "hi", "es", "fr", "ar", "bn", "pt-BR", "pt-PT", "ru",
            "ur", "id", "ms", "de", "ja", "sw", "mr", "te", "tr", "ta", "zh-Hant",
            "vi", "ko", "fa", "ha", "th", "gu", "pa", "fil", "it", "pl", "uk",
            "ml", "kn", "or", "my", "nl", "ro", "am", "uz", "sd", "yo", "ne",
            "si", "km", "cs", "sk", "sl", "hr", "ka", "el", "sv", "hu", "he", "da", "fi", "nb"
        ])
        check(Set(languages.map(\.rawValue)) == approved, "Language choices must exactly match the old app's 57 languages")
        check(Set(languages.map(\.rawValue)).count == languages.count, "Language codes must be unique")
        check(Set(bundle.localizations) == approved, "Only the approved languages may be bundled")
        check(Set(bundle.infoDictionary?["CFBundleLocalizations"] as? [String] ?? []) == approved,
              "The app manifest must advertise exactly the approved languages")
        let resourceDirectories = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }.map { $0.deletingPathExtension().lastPathComponent }
        check(Set(resourceDirectories) == approved, "Removed locales must not survive as stale compiled resources")
        func table(_ name: String, language: OathLanguage) throws -> [String: String] {
            let directory = url.appendingPathComponent("\(language.rawValue).lproj")
            let data = try Data(contentsOf: directory.appendingPathComponent("\(name).strings"))
            return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
        }
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var sourceCatalogs: [String: [String: Any]] = [:]
        for name in ["Localizable", "LanguageNames", "InfoPlist"] {
            let data = try Data(contentsOf: sourceRoot.appendingPathComponent("OathApp/Resources/\(name).xcstrings"))
            let catalog = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            sourceCatalogs[name] = catalog["strings"] as? [String: Any]
        }
        let en = OathLocalizer(.english, bundle: bundle), ar = OathLocalizer(.arabic, bundle: bundle)
        let rtl = Set(["ar", "fa", "he", "sd", "ur"])
        for language in languages {
            let strings = OathLocalizer(language, bundle: bundle)
            let appCopy = try table("Localizable", language: language)
            let languageNames = try table("LanguageNames", language: language)
            let permissionCopy = try table("InfoPlist", language: language)
            for (name, compiled) in [("Localizable", appCopy), ("LanguageNames", languageNames), ("InfoPlist", permissionCopy)] {
                for (key, rawEntry) in sourceCatalogs[name]! {
                    let entry = rawEntry as! [String: Any]
                    if entry["shouldTranslate"] as? Bool == false { continue }
                    if name == "InfoPlist" && !["NSFaceIDUsageDescription", "NSCameraUsageDescription"].contains(key) { continue }
                    let locales = entry["localizations"] as! [String: Any]
                    let translation = locales[language.rawValue] as! [String: Any]
                    let unit = translation["stringUnit"] as! [String: Any]
                    let expected = unit["value"] as! String
                    check(compiled[key] == expected, "Compiled text differs from reviewed source: \(language.rawValue)/\(name)/\(key)")
                }
            }
            check(language.isRightToLeft == rtl.contains(language.rawValue), "Native direction for \(language.rawValue)")
            if language.isRightToLeft {
                check(hasLeftToRightGroup(strings.format(.additionalNetworks, strings.number(9)), body: "+\(strings.number(9))"),
                      "The plus and count must share a LTR group: \(language.rawValue)")
                check(hasLeftToRightGroup(strings.format(.walletColorValue, "A1B2C3"), body: "#A1B2C3"),
                      "The hash and color code must share a LTR group: \(language.rawValue)")
            }
            check(!language.nativeName.isEmpty && language.nativeName != language.rawValue, "An actual native name must be present")
            check(language.flag.unicodeScalars.count == 2 && language.flag.unicodeScalars.allSatisfy { (0x1F1E6...0x1F1FF).contains($0.value) }, "Every language has a regional flag")
            let preference = OathLanguagePreference.language(language)
            check(OathLanguagePreference(rawValue: preference.rawValue) == preference, "Preference survives storage")
            check(preference.resolve(preferredLanguages: ["en"]) == language, "Explicit preference wins over system language")
            let evmTitle = strings.text(.evmTitle)
            check(OathPrivateKeyChoice.matching(evmTitle, localizedEVMTitle: evmTitle) == [.evm],
                  "Import group search accepts the displayed localized name: \(language.rawValue)")
            for key in OathStringKey.allCases {
                let value = strings.text(key), english = en.text(key)
                check(appCopy[key.rawValue] == value, "Compiled locale must contain the key without English fallback: \(language.rawValue)/\(key)")
                check(!value.isEmpty && value != key.rawValue, "Missing key: \(language.rawValue)/\(key)")
                func argumentPositions(_ text: String) -> [Int] {
                    var sequential = 1
                    return text.matches(of: /%(?:(\d+)\$)?@/).map { match in
                        if let explicit = match.output.1 { return Int(explicit)! }
                        defer { sequential += 1 }
                        return sequential
                    }.sorted()
                }
                check(argumentPositions(english) == argumentPositions(value), "Placeholder mismatch: \(language.rawValue)/\(key)")
            }
            for target in languages {
                let name = strings.name(of: target)
                let nameKey = OathLanguage.definitions.first { $0.code == target.rawValue }!.nameKey
                check(languageNames[nameKey] == name, "Compiled language names must not use fallback: \(language.rawValue)/\(target.rawValue)")
                check(!name.isEmpty && !name.hasPrefix("language."), "Every row has a display name in the selected language")
            }
        }
        check(OathLanguagePreference(rawValue: "unknown") == nil, "Invalid stored preferences fall back safely")
        check(OathLanguagePreference(rawValue: "system") == .system, "Device language option retains its stable identity")
        for code in ["ckb", "dv", "pcm", "af", "bal", "yi"] {
            check(OathLanguage(rawValue: code) == nil, "Removed language cannot be selected: \(code)")
            let preference = OathLanguagePreference(rawValue: code) ?? .system
            check(preference == .system, "A removed saved language uses the existing device-language fallback")
            check(preference.resolve(preferredLanguages: [code, "ar"]) == .arabic,
                  "A removed device language falls through to the next supported preference")
            check(preference.resolve(preferredLanguages: [code]) == .english,
                  "English is the final fallback for a removed language")
        }
        check(OathLanguage(rawValue: "pt") == nil, "Generic Portuguese is not an additional language choice")
        check(OathLanguagePreference(rawValue: "pt")?.rawValue == "pt-BR", "Earlier Portuguese selections migrate to Brazilian Portuguese")
        for code in ["pt-BR", "pt-PT"] {
            check(OathLanguage.resolve(preferredLanguages: [code]).rawValue == code, "Portuguese regions remain distinct")
            check(OathLanguagePreference(rawValue: code)?.rawValue == code, "Regional Portuguese preference round trip")
        }
        check(OathLanguage.resolve(preferredLanguages: ["pt"]).rawValue == "pt-BR", "Unqualified Portuguese uses the previous Brazilian default")
        check(en.name(of: OathLanguage(rawValue: "pt-BR")!) != en.name(of: OathLanguage(rawValue: "pt-PT")!),
              "Portuguese variants have distinct row labels")
        check(OathLanguage.resolve(preferredLanguages: ["zh-CN"]).rawValue == "zh-Hans", "Simplified Chinese selection")
        check(OathLanguage.resolve(preferredLanguages: ["zh-TW"]).rawValue == "zh-Hant", "Traditional Chinese selection")
        check(OathLanguage.resolve(preferredLanguages: ["ar-LB"]) == .arabic, "Arabic regions resolve to one language")
        check(OathLanguage.matching("Arabic", strings: en).contains(.arabic), "Search accepts English names")
        check(OathLanguage.matching("العربية", strings: en).contains(.arabic), "Search accepts native names")
        check(OathLanguage.matching("الإنجليزية", strings: ar).contains(.english), "Search accepts current-language names")
        check(Set(OathLanguage.matching("portugues", strings: en).map(\.rawValue)) == Set(["pt-BR", "pt-PT"]),
              "Search ignores diacritics and finds both Portuguese regions")
        check(OathLanguage.matching("no-such-language-xyz", strings: en).isEmpty, "Search has a real empty state")
        check(ar.format(.pinCount, ar.number(3), ar.number(6)).contains(ar.number(3)), "Localized PIN accessibility counts")
        let nativeNumbers = NumberFormatter()
        nativeNumbers.locale = OathLanguage.arabic.locale
        nativeNumbers.numberStyle = .decimal
        check(ar.number(14) == nativeNumbers.string(from: 14), "Arabic digits follow native number preferences")
        check(en.number(14) == "14", "English numbers stay native")
        check(ar.format(.additionalNetworks, ar.number(9)).contains(ar.number(9)), "Network remainder is formatted for Arabic")
        check(ar.invariant("iCloud") == "\u{2066}iCloud\u{2069}", "Mixed-script brand names are bidi-isolated")
        check(en.invariant("iCloud") == "iCloud", "English invariant is unchanged")
        check(OathLanguage.resolve(preferredLanguages: ["ar-SA", "en"]) == .arabic, "Arabic region resolution")
        check(OathLanguage.resolve(preferredLanguages: ["en-GB", "ar"]) == .english, "English region resolution")
        check(OathLanguage.resolve(preferredLanguages: ["zz-ZZ"]) == .english, "Unsupported languages fall back to English")
        check(OathLanguagePreference.english.resolve(preferredLanguages: ["ar"]) == .english, "Explicit language wins over system")
        check(OathLanguage.arabic.isRightToLeft && !OathLanguage.english.isRightToLeft, "Native locale direction")
        for supported in languages {
            let language = OathLocalizer(supported, bundle: bundle)
            let consent = try AttributedString(markdown: language.text(.consent))
            check(Set(consent.runs.compactMap(\.link)) == Set([URL(string: "https://oathwallet.org/terms")!, URL(string: "https://oathwallet.org/privacy")!]), "Both legal links survive translation")
            let info = Bundle(path: bundle.path(forResource: language.language.rawValue, ofType: "lproj")!)!
            let usage = info.localizedString(forKey: "NSFaceIDUsageDescription", value: nil, table: "InfoPlist")
            check(usage.contains("Face ID") && !usage.localizedCaseInsensitiveContains("Oath"), "System permission describes wallet access without app branding")
            check(usage != "NSFaceIDUsageDescription", "System permission is translated")
            let camera = info.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist")
            check(camera != "NSCameraUsageDescription" && !camera.isEmpty, "Camera permission is localized")
            check(!camera.localizedCaseInsensitiveContains("Oath"), "Camera explanation has no app branding")
        }
        for weight in ["Regular", "Medium", "SemiBold", "Bold"] {
            let name = "IBMPlexSansArabic-\(weight)"
            let file = bundle.url(forResource: name, withExtension: "ttf")!
            let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as! [CTFontDescriptor])[0]
            let font = CTFontCreateWithFontDescriptor(descriptor, 17, nil)
            check(CTFontCopyPostScriptName(font) as String == name, "Font registration name matches source")
            let characterSet = CTFontCopyCharacterSet(font) as CharacterSet
            check("محفظةشبكةإرسال".unicodeScalars.allSatisfy { characterSet.contains($0) }, "Arabic glyph coverage")
        }
        print("Passed \(checks) compiled-localization, language-registry, 57-language name, search, format, font, and preference checks.")
    }
}
