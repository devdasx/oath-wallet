import OathAezeed
import OathBitcoin
import Foundation
import Observation

/// Recovery input stays in this local editor until the user confirms an import.
@MainActor @Observable final class OathRecoveryPhraseDraft {
    var text = ""
    var preferElectrum = false
    var electrumKind: ElectrumSeedKind? { ElectrumMnemonic.kind(text) }
    var hasAmbiguousFormat: Bool { electrumKind != nil && validator?.verifiedPhrase(text) != nil && !isAezeed }
    var isElectrum: Bool { !isAezeed && electrumKind != nil && (!hasAmbiguousFormat || preferElectrum) }
    var isAezeed: Bool { Aezeed.recognizes(text) }
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
        guard !inputRejected, !isComposing, !isAezeed, !isElectrum else { return nil }
        return validator?.verifiedPhrase(text)
    }

    /// QR input accepts the same standard as typed/pasted input, never a URL,
    /// an address, an arbitrary JSON object, or an unchecked phrase.
    func receiveScan(_ payload: String) -> Bool {
        guard Aezeed.recognizes(payload) || ElectrumMnemonic.kind(payload) != nil || validator?.verifiedPhrase(payload) != nil else { return false }
        replace(with: payload)
        return true
    }

    func clear() {
        text = ""
        preferElectrum = false
        selection = NSRange(location: 0, length: 0)
        attemptedImport = false
        inputRejected = false
        isComposing = false
        editRevision &+= 1
    }

}
