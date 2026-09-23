import Foundation
import SwiftUI

enum MuunRecoveryImportInput {
    private static let recoveryAlphabet = Set(
        "ABCDEFHJKLMNPQRSTUVWXYZ2345789"
    )
    private static let base58Alphabet = Set(
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    )

    static func recoveryCode(_ input: String) -> String {
        let normalized = input
            .uppercased(with: Locale(identifier: "en_US_POSIX"))
            .filter { recoveryAlphabet.contains($0) }
            .prefix(32)
        return stride(from: 0, to: normalized.count, by: 4).map { offset in
            let start = normalized.index(normalized.startIndex, offsetBy: offset)
            let end = normalized.index(
                start,
                offsetBy: min(4, normalized.count - offset)
            )
            return String(normalized[start..<end])
        }.joined(separator: "-")
    }

    static func encryptedKey(_ input: String) -> String {
        String(input.filter { base58Alphabet.contains($0) }.prefix(160))
    }

    static func isValidRecoveryCode(_ input: String) -> Bool {
        (try? MuunRecoveryCode.canonical(input)) != nil
    }

    static func encryptedKeyValue(
        _ input: String
    ) -> MuunEncryptedPrivateKey? {
        try? MuunEncryptedPrivateKey(encoded: input)
    }

    static func manualInputsAreValid(
        firstEncryptedKey: String,
        secondEncryptedKey: String,
        recoveryCode: String
    ) -> Bool {
        guard isValidRecoveryCode(recoveryCode),
              let first = encryptedKeyValue(firstEncryptedKey),
              let second = encryptedKeyValue(secondEncryptedKey) else {
            return false
        }
        return first.birthdayBlock == second.birthdayBlock
    }
}

enum MuunRecoveryImportProcessor {
    static func readEmergencyKit(
        at url: URL
    ) async throws -> MuunEmergencyKitPayload {
        try Task.checkCancellation()
        let payload = try await Task.detached(priority: .userInitiated) {
            try MuunEmergencyKitPDFReader.read(url: url)
        }.value
        try Task.checkCancellation()
        return payload
    }

    static func emergencyKitDraft(
        payload: MuunEmergencyKitPayload,
        recoveryCode: String
    ) async throws -> WalletImportDraft {
        try Task.checkCancellation()
        let draft = try await Task.detached(priority: .userInitiated) {
            let material = try payload.recover(recoveryCode: recoveryCode)
            return try WalletCoreService.importMuunRecovery(material)
        }.value
        try Task.checkCancellation()
        return draft
    }

    static func encryptedKeysDraft(
        firstEncryptedKey: String,
        secondEncryptedKey: String,
        recoveryCode: String
    ) async throws -> WalletImportDraft {
        try Task.checkCancellation()
        let draft = try await Task.detached(priority: .userInitiated) {
            let material = try MuunRecoveryKeyDecryptor.recover(
                firstEncryptedKey: firstEncryptedKey,
                secondEncryptedKey: secondEncryptedKey,
                recoveryCode: recoveryCode
            )
            return try WalletCoreService.importMuunRecovery(material)
        }.value
        try Task.checkCancellation()
        return draft
    }
}

enum MuunRecoveryImportPresentation {
    static func errorKey(for error: Error) -> String {
        guard let recoveryError = error as? MuunRecoveryError else {
            return "muun.recovery.error.failed"
        }
        switch recoveryError {
        case .invalidRecoveryCode, .unsupportedRecoveryCodeVersion:
            return "muun.recovery.error.invalid_code"
        case .invalidEncryptedKey, .encryptedKeysDoNotMatch:
            return "muun.recovery.error.invalid_keys"
        case .invalidEmergencyKit:
            return "muun.recovery.error.invalid_kit"
        case .recoveryCodeDoesNotMatchEmergencyKit:
            return "muun.recovery.error.code_mismatch"
        case .decryptionFailed,
             .invalidKeyMaterial,
             .invalidDerivationPath,
             .derivationFailed:
            return "muun.recovery.error.failed"
        }
    }
}

struct MuunRecoveryMethodRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: UniHaptic.action(nil) {
            action()
        }) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(WalletTheme.primaryLabel)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.automatic)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(detail))
    }
}

struct MuunRecoveryCodeField: View {
    @Binding var value: String

    var body: some View {
        TextField("muun.recovery.code", text: $value)
            .walletTextInputDirection()
            .keyboardType(.asciiCapable)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .walletSensitiveValue()
            .onChange(of: value) { _, newValue in
                let sanitized = MuunRecoveryImportInput.recoveryCode(newValue)
                if value != sanitized { value = sanitized }
            }
    }
}

struct MuunEncryptedKeyField: View {
    let title: LocalizedStringKey
    @Binding var value: String

    var body: some View {
        SecureField(title, text: $value)
            .walletTextInputDirection()
            .keyboardType(.asciiCapable)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .walletSensitiveValue()
            .onChange(of: value) { _, newValue in
                let sanitized = MuunRecoveryImportInput.encryptedKey(newValue)
                if value != sanitized { value = sanitized }
            }
    }
}
