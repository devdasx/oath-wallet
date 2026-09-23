import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct BitcoinImportPresentationTests {
    @Test(arguments: [false, true], NativeListTestLayout.allCases)
    func fileActionOpensNativeSingleFilePicker(switcher: Bool, layout: NativeListTestLayout) async throws {
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                if switcher {
                    WalletSwitcherPrivateKeyImportScreen(network: .bitcoin) { _ in Issue.record("Picker must not import without a selection") }
                } else {
                    PrivateKeyCredentialView(network: .bitcoin) { _ in Issue.record("Picker must not import without a selection") }
                }
            }
        }
        defer { host.close() }
        let bundle = WalletAppLanguage.localizedBundle(for: layout.direction == .rightToLeft ? "ar" : "en")
        let label = bundle.localizedString(forKey: "import.bitcoin.file.choose", value: nil, table: nil)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            host.accessibilityAction(label: label, in: host.rootView) != nil
        }
        let action = try #require(host.accessibilityAction(label: label, in: host.rootView))
        #expect(action.accessibilityActivate())
        try await SendEntryUIProbe.wait(in: host.rootView) { picker(in: host) != nil }
        let documentPicker = try #require(picker(in: host))
        #expect(!documentPicker.allowsMultipleSelection)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BitcoinImport/descriptor-clear.dat")
        documentPicker.delegate?.documentPicker?(documentPicker, didPickDocumentsAt: [file])
        // A real document selection dismisses the system picker before returning
        // to the import screen. Reproduce that lifecycle after driving its delegate.
        documentPicker.dismiss(animated: false)
        try await SendEntryUIProbe.wait(in: host.rootView) { picker(in: host) == nil }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("bitcoinSelectedFileName", in: host.rootView) != nil
                && SendEntryUIProbe.views(UITextView.self, in: host.rootView).isEmpty
        }
        let name = try #require(SendEntryUIProbe.element("bitcoinSelectedFileName", in: host.rootView))
        #expect(name.accessibilityLabel == file.lastPathComponent)
        #expect(SendEntryUIProbe.views(UITextView.self, in: host.rootView).isEmpty)
        let replace = bundle.localizedString(forKey: "import.bitcoin.file.replace", value: nil, table: nil)
        let importTitle = bundle.localizedString(forKey: "import.private_key.action.import", value: nil, table: nil)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("bitcoinSelectedFileSize", in: host.rootView) != nil
                && host.accessibilityAction(label: importTitle, in: host.rootView) != nil
                && SendEntryUIProbe.element("bitcoinPrivateKeyHeadline", in: host.rootView) == nil
        }
        #expect(host.accessibilityAction(label: replace, in: host.rootView) != nil)
        #expect(host.accessibilityAction(label: label, in: host.rootView) == nil)
        let expectedBytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let size = try #require(SendEntryUIProbe.element("bitcoinSelectedFileSize", in: host.rootView))
        #expect(size.accessibilityLabel == Int64(expectedBytes).formatted(.byteCount(style: .file, spellsOutZero: false).locale(Locale(identifier: "en_US_POSIX"))))
        let replaceAction = try #require(host.accessibilityAction(label: replace, in: host.rootView))
        #expect(replaceAction.accessibilityActivate())
        try await SendEntryUIProbe.wait(in: host.rootView) { picker(in: host) != nil }
        let replacementPicker = try #require(picker(in: host))
        let replacement = file.deletingLastPathComponent().appendingPathComponent("legacy-clear.dat")
        replacementPicker.delegate?.documentPicker?(replacementPicker, didPickDocumentsAt: [replacement])
        replacementPicker.dismiss(animated: false)
        try await SendEntryUIProbe.wait(in: host.rootView) { picker(in: host) == nil }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("bitcoinSelectedFileName", in: host.rootView)?.accessibilityLabel == replacement.lastPathComponent
        }
        try SendEntryUIProbe.activate("bitcoinClearSelectedFile", in: host.rootView)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("bitcoinSelectedFileName", in: host.rootView) == nil
                && !SendEntryUIProbe.views(UITextView.self, in: host.rootView).isEmpty
                && SendEntryUIProbe.element("bitcoinPrivateKeyHeadline", in: host.rootView) != nil
                && host.accessibilityAction(label: label, in: host.rootView) != nil
        }

    }

    private func picker(in host: NativeListTestHost) -> UIDocumentPickerViewController? {
        var controller = host.rootView.window?.rootViewController
        while let current = controller {
            if let picker = current as? UIDocumentPickerViewController { return picker }
            controller = current.presentedViewController
        }
        return nil
    }
}
