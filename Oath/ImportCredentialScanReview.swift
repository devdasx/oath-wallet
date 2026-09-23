import Foundation

enum ImportWalletCredentialScannerMode: Hashable {
    case recoveryPhrase
    case privateKey(PrivateKeyImportNetwork)
}

enum ImportCredentialScanError: Error, Equatable {
    case empty
    case payloadTooLarge
    case invalidRecoveryPhrase
    case invalidPrivateKey

    var localizedMessage: String {
        switch self {
        case .empty:
            WalletLocalization.string(
                "smart_scanner.review.error.empty"
            )
        case .payloadTooLarge:
            WalletLocalization.string(
                "smart_scanner.review.error.payload_too_large"
            )
        case .invalidRecoveryPhrase:
            WalletLocalization.string(
                "import.scanner.review.error.invalid_recovery_phrase"
            )
        case .invalidPrivateKey:
            WalletLocalization.string(
                "import.scanner.review.error.invalid_private_key"
            )
        }
    }
}

struct ImportCredentialScanReview: Hashable {
    private static let maximumPayloadByteCount = 4_096

    let normalizedValue: String
    let mode: ImportWalletCredentialScannerMode
    let derivedAddress: String
    let wordCount: Int?

    static func parse(
        _ payload: String,
        mode: ImportWalletCredentialScannerMode
    ) throws -> Self {
        let trimmed = payload.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            throw ImportCredentialScanError.empty
        }
        guard trimmed.utf8.count <= maximumPayloadByteCount else {
            throw ImportCredentialScanError.payloadTooLarge
        }

        switch mode {
        case .recoveryPhrase:
            let normalized = trimmed
                .decomposedStringWithCompatibilityMapping
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .joined(separator: " ")
            guard
                BIP39MnemonicValidator.isValid(normalized),
                let draft = try? WalletCoreService
                    .importRecoveryPhrase(normalized)
            else {
                throw ImportCredentialScanError
                    .invalidRecoveryPhrase
            }
            return Self(
                normalizedValue: normalized,
                mode: mode,
                derivedAddress: draft.address,
                wordCount: normalized.split(separator: " ").count
            )

        case let .privateKey(network):
            if BitcoinBIP38.recognizes(trimmed, network: network) {
                return Self(normalizedValue: trimmed, mode: mode, derivedAddress: "", wordCount: nil)
            }
            guard
                let draft = try? PrivateKeyImportService.importKey(
                    trimmed,
                    network: network
                )
            else {
                throw ImportCredentialScanError.invalidPrivateKey
            }
            return Self(
                normalizedValue: trimmed,
                mode: mode,
                derivedAddress: draft.address,
                wordCount: nil
            )
        }
    }

    var presentation: SmartScannerReviewPresentation {
        switch mode {
        case .recoveryPhrase:
            return recoveryPhrasePresentation
        case let .privateKey(network):
            return privateKeyPresentation(network: network)
        }
    }

    private var recoveryPhrasePresentation:
        SmartScannerReviewPresentation {
        SmartScannerReviewPresentation(
            kind: .recoveryPhrase,
            titleKey: "import.scanner.review.recovery.title",
            detailKey: "import.scanner.review.recovery.detail",
            rows: [
                SmartScannerReviewRow(
                    id: "type",
                    titleKey: "smart_scanner.review.field.type",
                    value: WalletLocalization.string(
                        "smart_scanner.review.value.recovery_phrase"
                    )
                ),
                SmartScannerReviewRow(
                    id: "words",
                    titleKey: "smart_scanner.review.field.word_count",
                    value: EnglishNumbers.integer(
                        Int64(wordCount ?? 0)
                    )
                ),
                SmartScannerReviewRow(
                    id: "account",
                    titleKey:
                        "smart_scanner.review.field.derived_account",
                    value: derivedAddress,
                    valueStyle: .monospaced
                ),
                SmartScannerReviewRow(
                    id: "recovery_phrase",
                    titleKey:
                        "smart_scanner.review.field.recovery_phrase",
                    value: normalizedValue,
                    valueStyle: .secret
                )
            ],
            warningKey: "import.scanner.review.recovery.warning",
            primaryActionKey:
                "import.scanner.review.action.use_recovery_phrase"
        )
    }

    private func privateKeyPresentation(
        network: PrivateKeyImportNetwork
    ) -> SmartScannerReviewPresentation {
        SmartScannerReviewPresentation(
            kind: .privateKey,
            heroLogoSource: .nativeCoin(
                blockchain: network.blockchain
            ),
            titleKey: "import.scanner.review.private_key.title",
            detailKey: derivedAddress.isEmpty ? "import.bip38.message" : "import.scanner.review.private_key.detail",
            rows: [
                SmartScannerReviewRow(
                    id: "type",
                    titleKey: "smart_scanner.review.field.type",
                    value: WalletLocalization.string(
                        "smart_scanner.review.value.private_key"
                    )
                ),
                SmartScannerReviewRow(
                    id: "network",
                    titleKey: "smart_scanner.review.field.network",
                    value: network.localizedTitle
                ),
                SmartScannerReviewRow(
                    id: "account",
                    titleKey:
                        "smart_scanner.review.field.derived_account",
                    value: derivedAddress,
                    valueStyle: .monospaced
                ),
                SmartScannerReviewRow(
                    id: "private_key",
                    titleKey:
                        "smart_scanner.review.field.private_key",
                    value: normalizedValue,
                    valueStyle: .secret
                )
            ].filter { $0.id != "account" || !derivedAddress.isEmpty },
            warningKey: "import.scanner.review.private_key.warning",
            primaryActionKey:
                "import.scanner.review.action.use_private_key"
        )
    }
}
