import SwiftUI
import UIKit

struct BitcoinTransactionBroadcastView: View {
    @State private var rawTransactionHex = ""
    @State private var preview: BitcoinTransactionBroadcastPreview?
    @State private var result: BitcoinTransactionBroadcastResult?
    @State private var validationError:
        BitcoinTransactionBroadcastValidationError?
    @State private var broadcastError: BitcoinTransactionBroadcastError?
    @State private var isBroadcasting = false
    @State private var isScannerPresented = false
    @State private var copyFeedback = WalletClipboardCopyFeedback()
    @FocusState private var isInputFocused: Bool

    private let service: BitcoinTransactionBroadcastService

    init(
        service: BitcoinTransactionBroadcastService =
            BitcoinTransactionBroadcastService()
    ) {
        self.service = service
    }

    var body: some View {
        List {
            Group {
                inputSection

                if let preview {
                    transactionIDSection(preview)
                }

                if result != nil {
                    successSection
                } else if let errorMessage {
                    failureSection(errorMessage)
                }

                actionSection
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("settings.tools.broadcast_bitcoin.title")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .walletFocusOnPresentation { isInputFocused = true }
        .sheet(isPresented: $isScannerPresented) {
            NavigationStack {
                Group {
                    BitcoinTransactionQRScannerView { recognized in
                        replaceInput(with: recognized)
                    }
                }

            }
            .walletScannerPresentation()
        }
        .onDisappear {
            copyFeedback.reset()
        }
    }

    private var inputSection: some View {
        Section {
            TextField(
                "settings.tools.broadcast_bitcoin.input.title",
                text: inputBinding,
                axis: .vertical
            )
            .walletTextInputDirection()
            .walletNonHyphenatingInput()
            .lineLimit(12)
            .font(.body.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .focused($isInputFocused)

            HStack(spacing: 20) {
                Button("common.paste", action: UniHaptic.action(pasteFromClipboard))

                Button("common.scan", action: UniHaptic.action(nil) {
                    isInputFocused = false
                    isScannerPresented = true
                })

                Spacer(minLength: 0)

                if !rawTransactionHex.isEmpty {
                    Button("common.clear", role: .destructive, action: UniHaptic.action {
                        inputBinding.wrappedValue = ""
                    })
                }
            }
            .buttonStyle(.borderless)
        } footer: {
            Text("settings.tools.broadcast_bitcoin.input.footer")
        }
    }

    private func transactionIDSection(
        _ preview: BitcoinTransactionBroadcastPreview
    ) -> some View {
        Section("send.broadcast.transaction_id.title") {
            let displayedTransactionID = result?.transactionID
                ?? preview.transactionID

            WalletExactText(displayedTransactionID, monospaced: true, foregroundColor: WalletTheme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)

            if let result {
                if let explorerURL = WalletTransactionExplorer.url(
                    transactionHash: result.transactionID,
                    networkID: BitcoinFamilyChain.bitcoin.networkID
                ) {
                    Link(
                        "settings.tools.broadcast_bitcoin.view_on_explorer",
                        destination: explorerURL
                    )
                }

                Button(action: UniHaptic.action {
                    copyTransactionID(result.transactionID)
                }) {
                    Text(
                        LocalizedStringKey(
                            copyFeedback.state == .copied
                                ? "common.copied_to_clipboard"
                                : "wallet.transaction.details.copy_transaction_id"
                        )
                    )
                }
            }
        }
    }

    private var successSection: some View {
        Section {
            Text("send.broadcast.submitted.title")
                .foregroundStyle(WalletTheme.primaryLabel)
        }
    }

    private func failureSection(_ message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("send.broadcast.failed.title")
                    .foregroundStyle(WalletTheme.danger)
                Text(verbatim: message)
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionSection: some View {
        Section {
            Button(action: UniHaptic.action {
                Task { await broadcast() }
            }) {
                Text(
                    isBroadcasting
                        ? "send.broadcast.submitting.title"
                        : "settings.tools.broadcast_bitcoin.title"
                )
                .frame(maxWidth: .infinity)
            }
            .disabled(
                isBroadcasting
                    || result != nil
                    || rawTransactionHex.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
            )
        }
    }

    private var inputBinding: Binding<String> {
        Binding(
            get: { rawTransactionHex },
            set: { value in
                rawTransactionHex = value
                resetResult()
            }
        )
    }

    private var errorMessage: String? {
        if validationError != nil {
            return WalletLocalization.string(
                "settings.tools.broadcast_bitcoin.input.footer"
            )
        }
        guard let broadcastError else { return nil }
        switch broadcastError {
        case .notAttempted:
            return WalletLocalization.string(
                "send.submit.error.provider_transport"
            )
        case let .rejected(code, message):
            let detail = message ?? WalletLocalization.string(
                "send.submit.error.provider_no_message"
            )
            return EnglishNumbers.localized(
                "send.submit.error.broadcast_rejected",
                code as NSString,
                detail as NSString
            )
        case let .outcomeUnknown(code):
            return EnglishNumbers.localized(
                "send.submit.error.broadcast_unknown",
                "Bitcoin" as NSString,
                code as NSString
            )
        }
    }

    @MainActor
    private func pasteFromClipboard() {
        guard let value = UIPasteboard.general.string else { return }
        inputBinding.wrappedValue = value
        isInputFocused = true
        UniHaptic.play(.selection)
    }

    @MainActor
    private func replaceInput(
        with recognized: BitcoinTransactionBroadcastPreview
    ) {
        rawTransactionHex = recognized.normalizedHex
        resetResult()
        preview = recognized
        UniHaptic.play(.successQuiet)
    }

    @MainActor
    private func resetResult() {
        preview = nil
        result = nil
        validationError = nil
        broadcastError = nil
        copyFeedback.reset()
    }

    @MainActor
    private func copyTransactionID(_ transactionID: String) {
        SendTransactionIdentityClipboard.copy(
            transactionID,
            to: UIPasteboard.general
        )
        copyFeedback.markCopied()
        UniHaptic.play(.successQuiet)
        UIAccessibility.post(
            notification: .announcement,
            argument: WalletLocalization.string(
                copyFeedback.localizationKey
            )
        )
    }

    @MainActor
    private func broadcast() async {
        guard !isBroadcasting else { return }
        let prepared: BitcoinTransactionBroadcastPreview
        do {
            prepared = try service.preview(for: rawTransactionHex)
        } catch let error as BitcoinTransactionBroadcastValidationError {
            validationError = error
            broadcastError = nil
            UniHaptic.play(.error)
            return
        } catch {
            validationError = .invalid
            broadcastError = nil
            UniHaptic.play(.error)
            return
        }

        preview = prepared
        validationError = nil
        broadcastError = nil
        result = nil
        isInputFocused = false
        isBroadcasting = true
        defer { isBroadcasting = false }

        do {
            result = try await service.broadcast(prepared)
            UniHaptic.play(.success)
        } catch is CancellationError {
            return
        } catch let error as BitcoinTransactionBroadcastError {
            broadcastError = error
            UniHaptic.play(.error)
        } catch {
            broadcastError = .outcomeUnknown(code: "unexpected")
            UniHaptic.play(.error)
        }
    }
}

#Preview("Broadcast Bitcoin Transaction") {
    NavigationStack {
        BitcoinTransactionBroadcastView()
    }
}
