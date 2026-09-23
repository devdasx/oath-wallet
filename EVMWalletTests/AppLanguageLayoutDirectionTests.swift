import SwiftUI
import Testing
import UIKit
@testable import Aperture

@Suite(.serialized)
struct AppLanguageLayoutDirectionTests {
    @Test
    func requestedEuropeanAndAsianLanguagesRemainSupported() {
        let requestedIdentifiers: Set<String> = [
            "ms", "ka", "pt-PT", "nb", "hr", "sk", "sl"
        ]

        #expect(
            requestedIdentifiers.isSubset(
                of: Set(WalletAppLanguage.supportedIdentifiers)
            )
        )
    }

    @Test
    func everySupportedLanguageCatalogIsBundled() throws {
        for identifier in WalletAppLanguage.supportedIdentifiers {
            let path = try #require(
                Bundle.main.path(
                    forResource: identifier,
                    ofType: "lproj"
                ),
                "Missing bundled locale \(identifier)"
            )
            let bundle = try #require(Bundle(path: path))
            #expect(
                bundle.url(
                    forResource: "Localizable",
                    withExtension: "strings"
                ) != nil
            )
            #expect(
                bundle.url(
                    forResource: "InfoPlist",
                    withExtension: "strings"
                ) != nil
            )
        }
    }

    @Test
    func everySupportedLanguageHasLocalizedNamesAndAFlag() {
        let englishLocale = Locale(identifier: "en")

        for identifier in WalletAppLanguage.supportedIdentifiers {
            let language = SettingsLanguage(id: identifier)
            let localizedName = language.localizedName(in: englishLocale)
            let nativeName = language.nativeName
            let flagScalars = Array(language.flag.unicodeScalars)

            #expect(!localizedName.isEmpty)
            #expect(localizedName != identifier)
            #expect(!nativeName.isEmpty)
            #expect(nativeName != identifier)
            #expect(flagScalars.count == 2)
            #expect(
                flagScalars.allSatisfy {
                    (0x1F1E6...0x1F1FF).contains($0.value)
                }
            )
        }
    }

    @Test
    func languageTitleUsesUserLocaleWhileSubtitleUsesNativeLocale() {
        let spanish = SettingsLanguage(id: "es")

        #expect(
            spanish.localizedName(in: Locale(identifier: "en"))
                != spanish.localizedName(in: Locale(identifier: "fr"))
        )
        #expect(
            spanish.nativeName
                == Locale(identifier: "es")
                    .localizedString(forIdentifier: "es")
        )
    }

    @Test
    func everySupportedRightToLeftLanguageUsesRightToLeftLayout() {
        let expectedRightToLeftIdentifiers: Set<String> = [
            "ar", "fa", "he", "sd", "ur"
        ]
        let actualRightToLeftIdentifiers = Set(
            WalletAppLanguage.supportedIdentifiers.filter {
                WalletAppLanguage.layoutDirection(for: $0) == .rightToLeft
            }
        )

        #expect(
            actualRightToLeftIdentifiers == expectedRightToLeftIdentifiers
        )
    }

    @Test
    func everySupportedAppLocaleForcesLatinDecimalDigits() throws {
        for identifier in WalletAppLanguage.supportedIdentifiers {
            let locale = WalletAppLanguage.locale(for: identifier)
            #expect(
                locale.identifier.lowercased().contains("@numbers=latn")
            )

            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            let formatted = try #require(
                formatter.string(from: 1_234_567.89)
            )
            #expect(
                formatted.unicodeScalars
                    .filter(CharacterSet.decimalDigits.contains)
                    .allSatisfy { (0x30...0x39).contains($0.value) }
            )
        }
    }

    @Test
    func everyNumericKeypadUsesLeftToRightControlOrdering() {
        #expect(WalletNumericKeypadLayout.direction == .leftToRight)
        #expect(PasscodeEntryControlLayout.direction == .leftToRight)
    }

    @Test
    func representativeLeftToRightLanguagesRemainLeftToRight() {
        for identifier in ["en", "es", "hi", "zh-Hans", "zh-Hant"] {
            #expect(
                WalletAppLanguage.layoutDirection(for: identifier)
                    == .leftToRight
            )
        }
    }

    @Test
    func unsupportedIdentifiersUseTheEnglishFallbackDirection() {
        #expect(
            WalletAppLanguage.layoutDirection(for: "unsupported")
                == .leftToRight
        )
    }

    @Test @MainActor
    func everySupportedRTLTextEntryControlUsesRTLLeadingAlignment() async throws {
        let identifiers = WalletAppLanguage.supportedIdentifiers.filter {
            WalletAppLanguage.layoutDirection(for: $0) == .rightToLeft
        }

        for identifier in identifiers {
            try await checkTextEntryAlignment(languageIdentifier: identifier)
        }
    }

    @Test @MainActor
    func leftToRightTextEntryControlRemainsLeadingAligned() async throws {
        try await checkTextEntryAlignment(languageIdentifier: "en")
    }

    @Test @MainActor
    func systemSearchFieldUsesTheSelectedWritingDirection() async throws {
        for direction in [LayoutDirection.rightToLeft, .leftToRight] {
            let host = try hostedSearchField(layoutDirection: direction)
            defer { host.close() }
            try await SendEntryUIProbe.wait(in: host.rootView) {
                host.navigationController?.topViewController?.navigationItem.searchController != nil
            }
            let search = try #require(host.navigationController?.topViewController?.navigationItem.searchController)
            search.isActive = true
            let field = search.searchBar.searchTextField
            try await SendEntryUIProbe.wait(in: host.rootView) { field.window != nil }
            try await checkFocusedCaret(field, direction: direction, host: host)
        }
    }

    @MainActor
    private func hostedSearchField(
        layoutDirection: LayoutDirection
    ) throws -> NativeListTestHost {
        let rootView = NavigationStack {
            List {
                Text("Result")
            }
            .searchable(text: .constant("0x1234"), placement: .navigationBarDrawer(displayMode: .always))
            .walletTextInputDirection()
        }
        .environment(\.layoutDirection, layoutDirection)
        return try NativeListTestHost { rootView }
    }

    @MainActor
    private func hostedTextInputs(
        languageIdentifier: String
    ) throws -> NativeListTestHost {
        let direction = WalletAppLanguage.layoutDirection(
            for: languageIdentifier
        )
        let rootView = VStack {
            TextField("Field", text: .constant("0x1234"))
                .walletTextInputDirection()
            SecureField("Secure", text: .constant("secret"))
                .walletTextInputDirection()
            TextField(
                "Multiline",
                text: .constant("note"),
                axis: .vertical
            )
            .walletTextInputDirection()
            TextField(
                "Empty",
                text: .constant(""),
                prompt: Text(verbatim: "$0.00")
            )
            .walletTextInputDirection()
        }
        .multilineTextAlignment(WalletTextInputLayout.alignment)
        .environment(
            \.locale,
            WalletAppLanguage.locale(for: languageIdentifier)
        )
        .environment(\.layoutDirection, direction)
        return try NativeListTestHost { rootView }
    }

    @MainActor
    private func checkTextEntryAlignment(languageIdentifier: String) async throws {
        let direction = WalletAppLanguage.layoutDirection(for: languageIdentifier)
        let host = try hostedTextInputs(languageIdentifier: languageIdentifier)
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) { textInputs(in: host.rootView).count == 4 }
        let inputs = textInputs(in: host.rootView)
        #expect(inputs.contains { $0 is UITextView })
        #expect(Set(inputs.compactMap(textValue(of:))) == Set(["0x1234", "secret", "note", ""]))
        for input in inputs {
            #expect(input.effectiveUserInterfaceLayoutDirection ==
                    (direction == .rightToLeft ? .rightToLeft : .leftToRight))
            try await checkFocusedCaret(input, direction: direction, host: host)
            // UIKit can express SwiftUI's leading alignment as natural or as
            // the resolved physical edge after the field resigns.
            let alignment = textAlignment(of: input)
            #expect(alignment == .natural || alignment == (direction == .rightToLeft ? .right : .left))
        }
    }

    @MainActor
    private func checkFocusedCaret(
        _ input: UIView, direction: LayoutDirection, host: NativeListTestHost
    ) async throws {
        try await SendEntryUIProbe.wait(in: host.rootView) {
            input.isFirstResponder || input.becomeFirstResponder()
        }
        // Flush the host app's English editing notifications before applying
        // the fixture's policy. Production installs one policy at its app root;
        // a second global subscriber here would configure the same field twice.
        await Task.yield()
        host.rootView.layoutIfNeeded()
        WalletTextInputConfiguration.apply(direction, to: input)
        input.setNeedsLayout()
        input.layoutIfNeeded()
        let caret = endCaretMidX(of: input)
        let settledAlignment = textAlignment(of: input)
        #expect(settledAlignment == (direction == .rightToLeft ? .right : .left))
        #expect(caret.isFinite && caret >= 0 && caret <= input.bounds.width + 1)
        if direction == .rightToLeft {
            #expect(caret > input.bounds.midX)
        } else {
            #expect(caret < input.bounds.midX)
        }
        #expect(input.resignFirstResponder())
    }

    @MainActor
    private func textInputs(in view: UIView) -> [UIView] {
        let textInput = (view is UITextField || view is UITextView)
            ? [view]
            : []
        return textInput + view.subviews.flatMap(textInputs(in:))
    }

    @MainActor
    private func textAlignment(of textInput: UIView) -> NSTextAlignment {
        if let textField = textInput as? UITextField {
            return textField.textAlignment
        }
        if let textView = textInput as? UITextView {
            return textView.textAlignment
        }
        return .natural
    }

    @MainActor
    private func endCaretMidX(of textInput: UIView) -> CGFloat {
        if let textField = textInput as? UITextField {
            return textField.convert(textField.caretRect(for: textField.endOfDocument),
                                     from: textField.textInputView).midX
        }
        if let textView = textInput as? UITextView {
            return textView.convert(textView.caretRect(for: textView.endOfDocument),
                                    from: textView.textInputView).midX
        }
        return 0
    }

    @MainActor
    private func textValue(of textInput: UIView) -> String? {
        if let textField = textInput as? UITextField {
            return textField.text
        }
        if let textView = textInput as? UITextView {
            return textView.text
        }
        return nil
    }
}
