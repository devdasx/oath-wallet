import OathAezeed
import OathBitcoin
import Foundation
import Observation

enum OathRecoveryFormat: String, Hashable {
    case aezeed = "aezeed"
    case bip39 = "BIP-39"
    case electrum = "Electrum"
}

/// Recovery input stays in this local editor until the user confirms an import.
@MainActor @Observable final class OathRecoveryPhraseDraft {
    var text = "" {
        didSet { if oldValue != text { preferredFormat = nil } }
    }
    private(set) var preferredFormat: OathRecoveryFormat?
    var electrumKind: ElectrumSeedKind? { ElectrumMnemonic.kind(text) }

    var matchingFormats: [OathRecoveryFormat] {
        guard !inputRejected, !isComposing, let validator else { return [] }
        var formats: [OathRecoveryFormat] = []
        // Keep the existing defaults. Recognition identifies candidates; it cannot tell which wallet the user intended.
        if Aezeed.recognizes(text) { formats.append(.aezeed) }
        if validator.verifiedPhrase(text) != nil { formats.append(.bip39) }
        if electrumKind != nil { formats.append(.electrum) }
        return formats
    }

    func selectedFormat(in formats: [OathRecoveryFormat]) -> OathRecoveryFormat? {
        if let preferredFormat, formats.contains(preferredFormat) { return preferredFormat }
        return formats.first
    }

    func selectFormat(_ format: OathRecoveryFormat) {
        guard matchingFormats.contains(format) else { return }
        preferredFormat = format
    }

    var hasAmbiguousFormat: Bool { matchingFormats.count > 1 }
    var isElectrum: Bool { selectedFormat(in: matchingFormats) == .electrum }
    var isAezeed: Bool { selectedFormat(in: matchingFormats) == .aezeed }
    var selection = NSRange(location: 0, length: 0)
    var attemptedImport = false
    var inputRejected = false
    var isComposing = false
    private(set) var editRevision = 0
    private(set) var validator: OathMnemonicValidator?

    init(validator: OathMnemonicValidator? = OathMnemonicValidator.bundled) {
        self.validator = validator
    }

    var validation: OathMnemonicValidation {
        if inputRejected { return .tooLong }
        return validator?.validate(text) ?? .unavailable
    }
    var wordCount: Int { OathMnemonicValidator.words(in: text).count }
    var suggestions: [String] { validator?.suggestions(in: text, selection: selection) ?? [] }

    func replace(with value: String) {
        guard value.utf16.count <= OathMnemonicValidator.maximumInputLength else {
            inputRejected = true; attemptedImport = true
            return
        }
        text = value
        editRevision &+= 1
        isComposing = false
        selection = NSRange(location: value.utf16.count, length: 0)
        inputRejected = false
        attemptedImport = false
    }

    func complete(_ word: String) {
        guard let result = validator?.completing(word, in: text, selection: selection) else { return }
        text = result.text
        editRevision &+= 1
        selection = result.selection
        attemptedImport = false
        inputRejected = false
    }

    func submit() -> OathValidatedMnemonic? {
        attemptedImport = true
        guard selectedFormat(in: matchingFormats) == .bip39 else { return nil }
        return validator?.verifiedPhrase(text, explicitBIP39: preferredFormat == .bip39)
    }

    /// QR input accepts the same standard as typed/pasted input, never a URL,
    /// an address, an arbitrary JSON object, or an unchecked phrase.
    func receiveScan(_ payload: String) -> Bool {
        guard Aezeed.recognizes(payload) || ElectrumMnemonic.recognizesScannedPhrase(payload) || validator?.verifiedPhrase(payload) != nil else { return false }
        replace(with: payload)
        return true
    }

    func clear() {
        text = ""
        preferredFormat = nil
        selection = NSRange(location: 0, length: 0)
        attemptedImport = false
        inputRejected = false
        isComposing = false
        editRevision &+= 1
    }

}
