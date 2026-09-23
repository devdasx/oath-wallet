import CryptoKit
import SwiftUI
import UIKit

struct WalletICloudBackupToggle: View {
  @Binding var isEnabled: Bool
  let lastSuccessfulBackup: Date?
  let isDisabled: Bool
  let isLoading: Bool
  let accessibilityIdentifier: String
  let showsIcon: Bool

  init(
    isEnabled: Binding<Bool>,
    lastSuccessfulBackup: Date?,
    isDisabled: Bool,
    isLoading: Bool = false,
    accessibilityIdentifier: String = "wallet.icloud.backup.toggle",
    showsIcon: Bool = false
  ) {
    _isEnabled = isEnabled
    self.lastSuccessfulBackup = lastSuccessfulBackup
    self.isDisabled = isDisabled
    self.isLoading = isLoading
    self.accessibilityIdentifier = accessibilityIdentifier
    self.showsIcon = showsIcon
  }

  var body: some View {
    Group {
      if isLoading {
        HStack {
          label
          Spacer(minLength: 8)
          ZStack {
            // Measure the platform's switch, including OS-specific sizing, so
            // replacing progress with the real control never resizes the row.
            Toggle("", isOn: .constant(false))
              .labelsHidden()
              .hidden()
              .accessibilityHidden(true)
            ProgressView()
              .accessibilityLabel("wallet.launch.loading.accessibility")
              .accessibilityIdentifier(accessibilityIdentifier + ".loading")
          }
          .fixedSize()
        }
      } else {
        Toggle(isOn: $isEnabled) { label }
          .disabled(isDisabled)
          .accessibilityIdentifier(accessibilityIdentifier)
      }
    }
  }

  private var label: some View {
    HStack(spacing: 12) {
      if showsIcon {
        Image(systemName: "icloud")
          .foregroundStyle(WalletTheme.primaryLabel)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text("settings.wallets.backup.icloud")
          .foregroundStyle(WalletTheme.primaryLabel)
        if let lastSuccessfulBackup {
          Text(verbatim: EnglishNumbers.localized(
            "settings.wallets.backup.icloud.last_successful",
            EnglishNumbers.dateTime(lastSuccessfulBackup)
          ))
          .font(.subheadline)
          .foregroundStyle(WalletTheme.secondaryLabel)
        }
      }
    }
  }

}

struct WalletICloudBackupCompletionMarkerFailure: Error {
  let underlyingError: Error
}

struct WalletOperationFailurePresentation: Identifiable {
  let id = UUID()
  let messageKey: String
  let diagnosticReference: String

  init(messageKey: String, error: any Error) {
    self.messageKey = messageKey
    diagnosticReference = Self.diagnosticReference(for: error)
  }

  var message: String {
    [
      WalletLocalization.string(messageKey),
      EnglishNumbers.localized(
        "settings.wallets.operation.error.details",
        diagnosticReference
      ),
    ]
    .joined(separator: "\n\n")
  }

  var supportURL: URL? {
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = WalletSupport.emailAddress
    components.queryItems = [
      URLQueryItem(
        name: "subject",
        value: WalletLocalization.string(
          "settings.wallets.operation.support.subject"
        )
      ),
      URLQueryItem(
        name: "body",
        value: EnglishNumbers.localized(
          "settings.wallets.operation.support.body",
          diagnosticReference
        )
      ),
    ]
    return components.url
  }

  private static func diagnosticReference(
    for error: any Error
  ) -> String {
    if let markerFailure =
      error as? WalletICloudBackupCompletionMarkerFailure
    {
      return WalletCloudBackupDiagnostic(
        error: markerFailure.underlyingError
      ).reference
    }
    if let diagnostic = error.walletCloudBackupDiagnostic {
      return diagnostic.reference
    }
    if let category = error.walletCloudBackupCategory {
      return "WalletCloudBackupError.\(category.diagnosticCode)"
    }
    return WalletCloudBackupDiagnostic(error: error).reference
  }
}

enum WalletICloudPasskeyBackupCreation {
  @MainActor
  static func create(
    database: WalletDatabase,
    wallet: ManagedWallet,
    presentationAnchor: WalletPasskeyPresentationAnchor?,
    writePolicy: WalletCloudBackupWritePolicy = .replaceExisting,
    service: WalletAutomaticCloudBackupService = .shared
  ) async throws {
    var wallet = try await database.managedWallet(walletID: wallet.id)
    if writePolicy == .createOnly {
      if try await existingBackup(database: database, wallet: wallet, service: service) != nil {
        throw WalletCloudBackupReplacementRequired()
      }
      wallet = try await database.managedWallet(walletID: wallet.id)
    }
    let privateKeyMetadata =
      wallet.kind == .importedPrivateKey
      ? try await database.importedPrivateKeyMetadata(
        walletID: wallet.id
      )
      : nil
    let receipt = try await service
      .backup(
        wallet: wallet,
        privateKeyMetadata: privateKeyMetadata,
        presentationAnchor: presentationAnchor,
        writePolicy: writePolicy
      ) { authorization in
        try await database.sensitiveMaterialForICloudBackup(
          walletID: wallet.id,
          authorization: authorization
        )
      }

    do {
      try await database.markICloudBackupRemoteVerified(
        walletID: wallet.id,
        cloudWalletID: wallet.iCloudBackupWalletID ?? wallet.id,
        receipt: receipt
      )
    } catch {
      throw WalletICloudBackupCompletionMarkerFailure(
        underlyingError: error
      )
    }
  }

  /// Reconcile the live cloud identity, including restored wallets, before a
  /// create action decides whether replacement consent is required.
  static func existingBackup(
    database: WalletDatabase,
    wallet: ManagedWallet,
    service: WalletAutomaticCloudBackupService = .shared
  ) async throws -> ManagedWallet? {
    let identity: WalletCloudBackupRemoteIdentity
    do {
      identity = try await service.verifiedBackup(for: wallet)
    } catch WalletCloudBackupError.backupNotFound {
      try await database.clearICloudBackupRemoteVerification(walletID: wallet.id)
      return nil
    }
    do {
      try await database.markICloudBackupRemoteVerified(
        walletID: wallet.id,
        cloudWalletID: identity.walletID,
        receipt: identity.receipt
      )
    } catch {
      throw WalletICloudBackupCompletionMarkerFailure(underlyingError: error)
    }
    return try await database.managedWallet(walletID: wallet.id)
  }

  static func errorKey(for error: Error) -> String {
    if error is WalletICloudBackupCompletionMarkerFailure {
      return "settings.wallets.backup.icloud.local_status.error"
    }
    guard let backupError = error.walletCloudBackupCategory else {
      return "settings.wallets.backup.icloud.enable.error"
    }
    switch backupError {
    case .iCloudUnavailable:
      return "settings.wallets.backup.icloud.unavailable"
    case .passkeyCanceled, .passkeyAuthorizationFailed:
      return "settings.wallets.backup.passkey.authorization.error"
    case .passkeyConfigurationUnavailable:
      return "settings.wallets.backup.passkey.request.error"
    case .passkeyDeviceNotConfigured:
      return "settings.wallets.backup.passkey.device.error"
    case .passkeyPRFUnavailable:
      return "settings.wallets.backup.passkey.prf.error"
    case .passkeyPresentationUnavailable:
      return "settings.wallets.backup.passkey.presentation.error"
    case .passkeyCredentialMismatch, .invalidPasskeyCredential:
      return "settings.wallets.backup.passkey.credential.error"
    case .keychainFailure, .backupKeyUnavailable:
      return "settings.wallets.backup.icloud.key.error"
    case .randomGenerationFailed:
      return "settings.wallets.backup.passkey.request.error"
    case .storageFailed, .invalidBackupDocument:
      return "settings.wallets.backup.icloud.drive.error"
    case .remoteVerificationFailed:
      return "settings.wallets.backup.icloud.verification.error"
    default:
      return "settings.wallets.backup.icloud.enable.error"
    }
  }

  static func failure(
    for error: any Error
  ) -> WalletOperationFailurePresentation {
    WalletOperationFailurePresentation(
      messageKey: errorKey(for: error),
      error: error
    )
  }
}

enum WalletICloudBackupReconciliation {
  static func refresh(
    database: WalletDatabase,
    wallet: ManagedWallet,
    service: WalletAutomaticCloudBackupService = .shared
  ) async -> ManagedWallet {
    do {
      let identity = try await service.verifiedBackup(for: wallet)
      try await database.markICloudBackupRemoteVerified(
        walletID: wallet.id,
        cloudWalletID: identity.walletID,
        receipt: identity.receipt
      )
      return try await database.managedWallet(walletID: wallet.id)
    } catch {
      guard error.walletCloudBackupCategory == .backupNotFound else {
        // iCloud can be temporarily unavailable. Keep the last verified
        // state instead of incorrectly presenting the backup as deleted.
        return wallet
      }
      do {
        try await database.clearICloudBackupRemoteVerification(
          walletID: wallet.id
        )
        return try await database.managedWallet(walletID: wallet.id)
      } catch {
        return wallet
      }
    }
  }
}

struct WalletPrivateKeyCloudBackupConfiguration: Sendable {
  static let identityPrefix = "keymate-private-key-v1-"

  let cloudWalletID: String
  let walletName: String
  let sourceCreatedAt: Date
  let privateKeyData: Data
  var bitcoinImportedMaterial: BitcoinImportedWalletMaterial? = nil
  let metadata: WalletImportedPrivateKeyMetadata

  init(
    sourceWallet: ManagedWallet,
    itemTitle: String,
    encodedPrivateKey: String,
    network: PrivateKeyImportNetwork
  ) throws {
    let draft = try PrivateKeyImportService.importKey(
      encodedPrivateKey,
      network: network
    )
    let validatedNetwork: PrivateKeyImportNetwork
    let format: PrivateKeyImportFormat
    if case let .bitcoinImportedWallet(imported) = draft.secret, network == .bitcoin {
      bitcoinImportedMaterial = imported
      privateKeyData = Data()
      validatedNetwork = .bitcoin
      format = .wifCompressed
    } else if case let .privateKey(data, selectedNetwork, selectedFormat) = draft.secret,
              selectedNetwork == network, data.count == 32 {
      privateKeyData = data
      validatedNetwork = selectedNetwork
      format = selectedFormat
    } else { throw WalletPrivateKeyExportError.invalidSecret }

    metadata = WalletImportedPrivateKeyMetadata(
      network: validatedNetwork,
      format: format,
      address: draft.address
    )
    sourceCreatedAt = sourceWallet.createdAt

    if let linkedID = sourceWallet.iCloudBackupWalletID,
      linkedID.hasPrefix(Self.identityPrefix)
    {
      cloudWalletID = linkedID
      walletName = sourceWallet.name
    } else {
      let sourceIdentity = sourceWallet.iCloudBackupWalletID
        ?? sourceWallet.id
      cloudWalletID = Self.cloudIdentity(
        sourceIdentity: sourceIdentity,
        network: validatedNetwork,
        format: format,
        address: draft.normalizedAddress
      )
      walletName = Self.backupName(
        sourceName: sourceWallet.name,
        itemTitle: itemTitle,
        address: draft.address
      )
    }
  }

  var backupWallet: ManagedWallet {
    ManagedWallet(
      id: cloudWalletID,
      name: walletName,
      kind: .importedPrivateKey,
      address: metadata.address,
      fiatUSDBalance: 0,
      isSelected: false,
      notificationsEnabledWhenInactive: false,
      backupState: .notVerified,
      backupVerifiedAt: nil,
      iCloudBackupUpdatedAt: nil,
      mnemonicWordCount: nil,
      createdAt: sourceCreatedAt
    )
  }

  @MainActor
  func createBackup(
    using service: WalletAutomaticCloudBackupService = .shared,
    presentationAnchor: WalletPasskeyPresentationAnchor? = nil,
    writePolicy: WalletCloudBackupWritePolicy = .createOnly
  ) async throws -> WalletCloudBackupReceipt {
    let wallet = backupWallet
    let material = bitcoinImportedMaterial.map(WalletSensitiveMaterial.bitcoinImportedWallet)
      ?? .privateKey(privateKeyData.hexString)
    return try await service.backup(
      wallet: wallet,
      privateKeyMetadata: metadata,
      presentationAnchor: presentationAnchor,
      writePolicy: writePolicy
    ) { authorization in
      guard authorization.permits(walletID: wallet.id) else {
        throw WalletCloudBackupError.encryptionFailed
      }
      return material
    }
  }

  func descriptor(
    using service: WalletAutomaticCloudBackupService = .shared
  ) async throws -> WalletCloudBackupDescriptor {
    try await service.backupDescriptor(walletID: cloudWalletID)
  }

  func removeBackup(
    using service: WalletAutomaticCloudBackupService = .shared
  ) async throws {
    try await service.removeBackup(walletID: cloudWalletID)
  }

  private static func cloudIdentity(
    sourceIdentity: String,
    network: PrivateKeyImportNetwork,
    format: PrivateKeyImportFormat,
    address: String
  ) -> String {
    var context = Data()
    for component in [
      "keymate.private-key-backup.v1",
      sourceIdentity,
      network.rawValue,
      format.rawValue,
      address,
    ] {
      let data = Data(component.utf8)
      var length = UInt64(data.count).bigEndian
      withUnsafeBytes(of: &length) {
        context.append(contentsOf: $0)
      }
      context.append(data)
    }
    return identityPrefix + Data(SHA256.hash(data: context)).hexString
  }

  private static func backupName(
    sourceName: String,
    itemTitle: String,
    address: String
  ) -> String {
    let addressSummary: String
    if address.count > 14 {
      addressSummary = String(address.prefix(6))
        + "…"
        + String(address.suffix(6))
    } else {
      addressSummary = address
    }
    let suffix = " • \(itemTitle) • \(addressSummary)"
    let availableSourceLength = max(
      1,
      WalletDefaultName.maximumLength - suffix.count
    )
    let candidate = String(sourceName.prefix(availableSourceLength))
      + suffix
    return String(candidate.prefix(WalletDefaultName.maximumLength))
  }
}

struct WalletPrivateKeyICloudBackupToggle: View {
  let wallet: ManagedWallet
  let item: WalletPrivateKeyExportItem
  let privateKey: WalletPrivateKeyExportValue
  let service: WalletAutomaticCloudBackupService

  @Environment(\.openURL) private var openURL
  @State private var configuration:
    WalletPrivateKeyCloudBackupConfiguration?
  @State private var isEnabled = false
  @State private var lastSuccessfulBackup: Date?
  @State private var isPreparing = true
  @State private var isUpdating = false
  @State private var showsReplacementConfirmation = false
  @State private var actionTask: Task<Void, Never>?
  @State private var passkeyPresentationWindow: UIWindow?
  @State private var operationFailure:
    WalletOperationFailurePresentation?

  init(
    wallet: ManagedWallet,
    item: WalletPrivateKeyExportItem,
    privateKey: WalletPrivateKeyExportValue,
    service: WalletAutomaticCloudBackupService = .shared
  ) {
    self.wallet = wallet
    self.item = item
    self.privateKey = privateKey
    self.service = service
  }

  var body: some View {
    WalletICloudBackupToggle(
      isEnabled: backupBinding,
      lastSuccessfulBackup: lastSuccessfulBackup,
      isDisabled: isPreparing || isUpdating || configuration == nil,
      accessibilityIdentifier: "wallet.private_key.icloud_backup"
    )
    .background {
      WalletPasskeyPresentationAnchorReader { window in
        if passkeyPresentationWindow !== window {
          passkeyPresentationWindow = window
        }
      }
      .frame(width: 0, height: 0)
    }
    .task(id: preparationIdentity) {
      await prepareAndRefresh()
    }
    .onDisappear {
      actionTask?.cancel()
      actionTask = nil
    }
    .confirmationDialog(
      "settings.wallets.backup.replace.title",
      isPresented: $showsReplacementConfirmation,
      titleVisibility: .visible
    ) {
      Button("settings.wallets.backup.replace.confirm", role: .destructive, action: UniHaptic.action {
        if let configuration {
          updateBackup(configuration: configuration, writePolicy: .replaceExisting)
        }
      })
      Button("settings.wallets.backup.replace.keep", role: .cancel, action: UniHaptic.action {})
    } message: {
      Text("settings.wallets.backup.replace.private_key.message")
    }
    .alert(
      "settings.wallets.operation.error.title",
      isPresented: operationFailureBinding
    ) {
      if let supportURL = operationFailure?.supportURL {
        Button("wallet.persistence.contact_support", action: UniHaptic.action(nil) {
          openURL(supportURL)
        })
      }
      Button("common.done", role: .cancel, action: UniHaptic.action {
        operationFailure = nil
      })
    } message: {
      if let operationFailure {
        Text(verbatim: operationFailure.message)
      }
    }
  }

  private var preparationIdentity: String {
    "\(wallet.id):\(item.id):\(privateKey.kind.rawValue)"
  }

  private var backupBinding: Binding<Bool> {
    Binding(
      get: { isEnabled },
      set: { requestedValue in
        guard requestedValue != isEnabled,
          !isPreparing,
          !isUpdating,
          let configuration
        else { return }
        updateBackup(configuration: configuration, writePolicy: .createOnly)
      }
    )
  }

  private var operationFailureBinding: Binding<Bool> {
    Binding(
      get: { operationFailure != nil },
      set: { isPresented in
        if !isPresented {
          operationFailure = nil
        }
      }
    )
  }

  @MainActor
  private func prepareAndRefresh() async {
    isPreparing = true
    isEnabled = false
    lastSuccessfulBackup = nil
    configuration = nil

    let sourceWallet = wallet
    let itemTitle = item.localizedTitle
    let encodedPrivateKey = privateKey.value
    let network = item.backupNetwork
    let prepared = await Task.detached(priority: .userInitiated) {
      try? WalletPrivateKeyCloudBackupConfiguration(
        sourceWallet: sourceWallet,
        itemTitle: itemTitle,
        encodedPrivateKey: encodedPrivateKey,
        network: network
      )
    }.value
    guard !Task.isCancelled else { return }
    configuration = prepared

    if let prepared {
      do {
        let descriptor = try await prepared.descriptor(
          using: service
        )
        guard !Task.isCancelled else { return }
        isEnabled = true
        lastSuccessfulBackup = descriptor.backedUpAt
      } catch WalletCloudBackupError.backupNotFound {
        guard !Task.isCancelled else { return }
        isEnabled = false
        lastSuccessfulBackup = nil
      } catch {
        guard !Task.isCancelled else { return }
        operationFailure = WalletICloudPasskeyBackupCreation.failure(for: error)
      }
    }
    isPreparing = false
  }

  @MainActor
  private func updateBackup(
    configuration: WalletPrivateKeyCloudBackupConfiguration,
    writePolicy: WalletCloudBackupWritePolicy
  ) {
    isUpdating = true
    actionTask?.cancel()
    actionTask = Task { @MainActor in
      defer {
        isUpdating = false
        actionTask = nil
      }
      do {
        let receipt = try await configuration.createBackup(
          using: service,
          presentationAnchor: passkeyPresentationWindow,
          writePolicy: writePolicy
        )
        self.isEnabled = true
        lastSuccessfulBackup = receipt.serverModifiedAt
        UniHaptic.play(.successQuiet)
      } catch is CancellationError {
      } catch is WalletCloudBackupReplacementRequired {
        self.isEnabled = true
        showsReplacementConfirmation = true
      } catch {
        if error.walletCloudBackupCategory == .passkeyCanceled {
          return
        }
        operationFailure = WalletOperationFailurePresentation(
          messageKey: WalletICloudPasskeyBackupCreation.errorKey(for: error),
          error: error
        )
        UniHaptic.play(.error)
      }
    }
  }
}

struct WalletPasskeyPresentationAnchorReader: UIViewRepresentable {
  let onChange: @MainActor (UIWindow?) -> Void

  func makeUIView(context: Context) -> AnchorView {
    AnchorView(onChange: onChange)
  }

  func updateUIView(_ view: AnchorView, context: Context) {
    view.onChange = onChange
    view.publishWindowIfNeeded()
  }

  @MainActor
  final class AnchorView: UIView {
    var onChange: @MainActor (UIWindow?) -> Void
    private weak var publishedWindow: UIWindow?

    init(onChange: @escaping @MainActor (UIWindow?) -> Void) {
      self.onChange = onChange
      super.init(frame: .zero)
      isUserInteractionEnabled = false
      backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      publishWindowIfNeeded()
    }

    func publishWindowIfNeeded() {
      guard publishedWindow !== window else { return }
      publishedWindow = window
      onChange(window)
    }
  }
}
