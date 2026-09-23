import GRDB
import SwiftUI
import Testing
import UIKit
@testable import Aperture

/// Native presentation hosts can start with the system language even when the
/// app uses another language. Exercise the production flows with that mismatch.
@MainActor
@Suite(.serialized)
struct NativePresentationLanguageTests {
    @Test(arguments: ["ar", "fa", "he", "ur", "sd", "en"],
          [NativeListTestLayout.phone, .padLandscape, .largeTextRTL])
    func bitcoinSettingsAndItsChildUseTheSelectedLanguage(
        language: String, layout: NativeListTestLayout
    ) async throws {
        let previousLanguage = WalletRuntimePreferences.shared.languageIdentifier
        defer { WalletRuntimePreferences.shared.setLanguageIdentifier(previousLanguage) }
        let database = try await bitcoinDatabase()
        let settings = settings(database: database, language: language)
        let expected = nativeDirection(language)
        let host = try NativeListTestHost(layout: layout) {
            BitcoinWalletSettingsFlow(walletID: "rtl-bitcoin", database: database)
                .environment(settings)
                .environment(\.locale, Locale(identifier: language == "en" ? "ar" : "en"))
                .environment(\.layoutDirection, language == "en" ? .rightToLeft : .leftToRight)
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 3 && $0.numberOfItems(inSection: 1) == 2 }
        let navigation = try #require(host.navigationController)
        #expect(list.effectiveUserInterfaceLayoutDirection == expected)
        #expect(navigation.navigationBar.effectiveUserInterfaceLayoutDirection == expected)
        #expect(navigation.topViewController?.navigationItem.title
            == WalletLocalization.string("bitcoin.settings.title"))

        let row = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        // Disclosure symbols belong to the native NavigationLink. Verify the
        // row's effective direction without depending on private symbol views.
        #expect(row.effectiveUserInterfaceLayoutDirection == expected)

        try await host.selectNavigationRow(IndexPath(item: 0, section: 1), in: list)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil
        }
        let childList = try await host.list { $0.numberOfSections == 4 }
        #expect(childList.effectiveUserInterfaceLayoutDirection == expected)
        #expect(navigation.navigationBar.effectiveUserInterfaceLayoutDirection == expected)
        #expect(navigation.topViewController?.navigationItem.title == BitcoinHDAddressType.bip84.localizedName)
        navigation.popViewController(animated: false)
        try await SendEntryUIProbe.wait(in: host.rootView) { navigation.viewControllers.count == 1 }
        #expect(list.effectiveUserInterfaceLayoutDirection == expected)
    }

    @Test(arguments: ["ar", "en"], ["entropy", "passphrase", "reset", "remove"])
    func educationalSheetsUseTheAppLanguage(language: String, screen: String) async throws {
        let previousLanguage = WalletRuntimePreferences.shared.languageIdentifier
        defer { WalletRuntimePreferences.shared.setLanguageIdentifier(previousLanguage) }
        let database = try WalletDatabase.temporary()
        let settings = settings(database: database, language: language)
        let host = try NativeListTestHost {
            Group {
                switch screen {
                case "entropy": OnboardingEntropyLearnMoreSheet()
                case "passphrase": OnboardingPassphraseLearnMoreSheet()
                case "reset": ResetAppLearnMoreSheet()
                default: RemoveWalletLearnMoreSheet()
                }
            }
            .environment(settings)
            .environment(\.layoutDirection, language == "en" ? .rightToLeft : .leftToRight)
        }
        defer { host.close() }
        let list = try await host.list()
        #expect(list.effectiveUserInterfaceLayoutDirection == nativeDirection(language))
        let navigation = try #require(host.navigationController)
        #expect(navigation.navigationBar.effectiveUserInterfaceLayoutDirection == nativeDirection(language))
    }

    @Test
    func anAlreadyPresentedBitcoinSheetRespondsToLanguageChanges() async throws {
        let previousLanguage = WalletRuntimePreferences.shared.languageIdentifier
        defer { WalletRuntimePreferences.shared.setLanguageIdentifier(previousLanguage) }
        let database = try await bitcoinDatabase()
        let settings = settings(database: database, language: "ar")
        let host = try NativeListTestHost {
            BitcoinLanguageSheetProbe(database: database).environment(settings)
        }
        defer { host.close() }
        let root = try #require(host.rootView.window?.rootViewController)
        try await SendEntryUIProbe.wait(in: root.view) { root.presentedViewController != nil }
        let presented = try #require(root.presentedViewController)
        defer { presented.dismiss(animated: false) }
        for language in ["ar", "en", "fa"] {
            settings.setLanguageIdentifier(language)
            try await SendEntryUIProbe.wait(in: presented.view) {
                guard let list = SendEntryUIProbe.views(UICollectionView.self, in: presented.view).first else {
                    return false
                }
                return list.numberOfSections == 3
                    && list.effectiveUserInterfaceLayoutDirection == nativeDirection(language)
            }
            #expect(root.presentedViewController === presented)
        }
        await settings.flush()
    }

    private func settings(database: WalletDatabase, language: String) -> WalletSettingsStore {
        var preferences = WalletApplicationSettings.default
        preferences.languageIdentifier = language
        return WalletSettingsStore(database: database, initialSettings: preferences)
    }

    private func nativeDirection(_ language: String) -> UIUserInterfaceLayoutDirection {
        WalletAppLanguage.layoutDirection(for: language) == .rightToLeft ? .rightToLeft : .leftToRight
    }

    private func bitcoinDatabase() async throws -> WalletDatabase {
        let database = try WalletDatabase.temporary()
        // Public BIP84 test-vector account; no wallet secret or network requests.
        let publicKey = "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYf"
            + "G1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUU"
            + "kgDKf31mGDtKsAYz2oz2AGutZYs"
        try await database.pool.write { db in
            try DBWalletRecord(id: "rtl-bitcoin", profileID: WalletDatabase.defaultProfileID,
                name: "RTL fixture", kind: DatabaseWalletKind.watchOnly.rawValue,
                secretKeyReference: nil, isSelected: true, sortOrder: 0,
                createdAt: 1, updatedAt: 1, lastOpenedAt: nil, archivedAt: nil).insert(db)
            try DBBitcoinHDAccountRecord(walletID: "rtl-bitcoin", addressType: "bip84",
                accountIndex: 0, accountPath: BitcoinHDAddressType.bip84.accountPath,
                extendedPublicKey: publicKey, createdAt: 1, updatedAt: 1).insert(db)
        }
        return database
    }
}

private struct BitcoinLanguageSheetProbe: View {
    let database: WalletDatabase
    @State private var isPresented = false

    var body: some View {
        Color.clear
            .task { isPresented = true }
            .sheet(isPresented: $isPresented) {
                BitcoinWalletSettingsFlow(walletID: "rtl-bitcoin", database: database)
            }
    }
}
