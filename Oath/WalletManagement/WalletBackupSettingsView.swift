import SwiftUI
import UIKit

struct WalletBackupSettingsView: View {
  let database: WalletDatabase
  let walletID: String
  let onWalletChanged: () -> Void

  @Environment(\.openURL) private var openURL
  @State private var wallet: ManagedWallet?
  @State private var isLoading = true
  @State private var errorKey: String?
  @State private var materialPresentation: WalletSensitiveMaterialPresentation?
  @State private var privateKeyItems: [WalletPrivateKeyExportItem] = []
  @State private var isPrivateKeyExportPresented = false
  @State private var pendingSensitiveAction: WalletSensitiveAction?
  @State private var sensitiveAuthenticationContext:
    WalletAuthenticationPasscodeContext?
  @State private var isSensitiveAuthenticationPresented = false
  @State private var pendingSensitiveGrant: WalletAuthenticationGrant?
  @State private var secretAccessTask: Task<Void, Never>?
  @State private var isAccessingWalletSecret = false
  @State private var passkeyPresentationWindow: UIWindow?
  @State private var operationFailure:
    WalletOperationFailurePresentation?
  @State private var isICloudBackupEnabled = false
  @State private var isUpdatingICloudBackup = false

  var body: some View {
    List {
        Group {
          if isLoading {
            Section("settings.wallets.details.section") {
              Text("wallet.launch.loading.accessibility")
                .foregroundStyle(WalletTheme.secondaryLabel)
            }
          } else if let errorKey {
            Section {
              WalletManagementErrorRow(
                messageKey: errorKey,
                onRetry: loadWallet
              )
            }
          } else if let wallet {
            backupOptions(wallet)
          }
        }
        .walletListRowSurface()
    }
    .walletListAppearance()
    .listStyle(.insetGrouped)
    .navigationTitle("settings.wallets.backup.wallet")
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(
      isPresented: privateKeyExportBinding
    ) {
      if let wallet {
        WalletPrivateKeyExportFlow(
          wallet: wallet,
          items: privateKeyItems
        )
      }
    }
    .fullScreenCover(
      isPresented: sensitiveAuthenticationBinding,
      onDismiss: sensitiveAuthenticationDidDismiss
    ) {
      if let context = sensitiveAuthenticationContext {
        WalletAuthenticationFullScreenContainer(
          title: "security.authentication.navigation_title"
        ) {
          WalletSecurityAuthenticationView(
            database: database,
            settings: context.settings,
            purpose: .walletSensitiveData,
            beginsWithPasscode: true,
            initialErrorKey: context.initialErrorKey,
            onAuthenticationGranted: completeSensitiveAuthentication
          )
        }
      }
    }
    .navigationDestination(
      isPresented: sensitiveMaterialDestinationBinding
    ) {
      if let wallet,
        let presentation = materialPresentation
      {
        WalletSensitiveAccessView(
          database: database,
          wallet: wallet,
          action: presentation.action,
          material: presentation.material,
          onBackupCompleted: {
            loadWallet()
            onWalletChanged()
          }
        )
      }
    }
    .task {
      await loadWalletAsync()
    }
    .background {
      WalletPasskeyPresentationAnchorReader { window in
        if passkeyPresentationWindow !== window {
          passkeyPresentationWindow = window
        }
      }
      .frame(width: 0, height: 0)
    }
    .onDisappear {
      secretAccessTask?.cancel()
      secretAccessTask = nil
    }
    .alert(
      "settings.wallets.operation.error.title",
      isPresented: Binding(
        get: { operationFailure != nil },
        set: { presented in
          if !presented {
            operationFailure = nil
          }
        }
      )
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

  private var sensitiveMaterialDestinationBinding: Binding<Bool> {
    Binding(
      get: { materialPresentation != nil },
      set: { isPresented in
        if !isPresented {
          materialPresentation = nil
          loadWallet()
        }
      }
    )
  }

  @ViewBuilder
  private func backupOptions(_ wallet: ManagedWallet) -> some View {
    if wallet.kind.hasExportableSecret {
      Section {
        if wallet.kind.hasRecoveryPhrase {
          Button(action: UniHaptic.action(nil) { requestSensitiveAction(.viewRecoveryPhrase, wallet: wallet) }) {
            Label("settings.wallets.recovery.view", systemImage: "text.page")
              .foregroundStyle(WalletTheme.accent)
          }
          Button(action: UniHaptic.action(nil) { requestSensitiveAction(.privateKeyExport, wallet: wallet) }) {
            Label("settings.wallets.private_keys.export", systemImage: "key.horizontal")
              .foregroundStyle(WalletTheme.accent)
          }
          Button(action: UniHaptic.action(nil) { requestSensitiveAction(.manualBackup, wallet: wallet) }) {
            LabeledContent {
              if wallet.backupState != .verified {
                Text("settings.wallets.backup.status.not_complete")
                  .foregroundStyle(WalletTheme.secondaryLabel)
              }
            } label: {
              Label("settings.wallets.backup.manual", systemImage: "square.and.pencil")
                .foregroundStyle(WalletTheme.accent)
            }
          }
        } else if wallet.kind == .importedPrivateKey {
          Button(action: UniHaptic.action(nil) { requestSensitiveAction(.privateKeyExport, wallet: wallet) }) {
            Label("settings.wallets.private_key.view", systemImage: "key.horizontal")
              .foregroundStyle(WalletTheme.accent)
          }
        }
        WalletICloudBackupToggle(
          isEnabled: iCloudBackupBinding(wallet: wallet),
          lastSuccessfulBackup: wallet.iCloudBackupUpdatedAt,
          isDisabled: isUpdatingICloudBackup || isAccessingWalletSecret,
          showsIcon: true
        )
      } footer: {
        Text("settings.wallets.backup.keychain.footer")
      }
      .disabled(isAccessingWalletSecret)
    }
  }

  private func loadWallet() {
    Task {
      await loadWalletAsync()
    }
  }

  private var privateKeyExportBinding: Binding<Bool> {
    Binding(
      get: { isPrivateKeyExportPresented },
      set: { isPresented in
        if !isPresented {
          isPrivateKeyExportPresented = false
          privateKeyItems.removeAll(keepingCapacity: false)
        }
      }
    )
  }

  private var sensitiveAuthenticationBinding: Binding<Bool> {
    Binding(
      get: { isSensitiveAuthenticationPresented },
      set: { isPresented in
        isSensitiveAuthenticationPresented = isPresented
      }
    )
  }

  private func requestSensitiveAction(
    _ action: WalletSensitiveAction,
    wallet: ManagedWallet
  ) {
    guard !isAccessingWalletSecret, sensitiveAuthenticationContext == nil else { return }
    pendingSensitiveAction = action
    isAccessingWalletSecret = true
    secretAccessTask = Task { @MainActor in
      defer {
        isAccessingWalletSecret = false
        secretAccessTask = nil
      }
      do {
        let preparation = try await WalletSensitiveActionAuthorizer
          .prepare(database: database)
        guard !Task.isCancelled else { return }
        switch preparation {
        case let .authorized(grant):
          try await executeSensitiveAction(
            action,
            wallet: wallet,
            grant: grant
          )
          pendingSensitiveAction = nil
        case let .requiresPasscode(context):
          sensitiveAuthenticationContext = context
          isSensitiveAuthenticationPresented = true
        case .cancelled:
          pendingSensitiveAction = nil
        }
      } catch is CancellationError {
      } catch {
        handleSensitiveActionFailure(error, action: action)
      }
    }
  }

  private func completeSensitiveAuthentication(
    _ grant: WalletAuthenticationGrant
  ) {
    pendingSensitiveGrant = grant
    isSensitiveAuthenticationPresented = false
  }

  private func sensitiveAuthenticationDidDismiss() {
    let grant = pendingSensitiveGrant
    let action = pendingSensitiveAction
    pendingSensitiveGrant = nil
    pendingSensitiveAction = nil
    sensitiveAuthenticationContext = nil
    guard let grant, let action, let wallet else { return }
    beginSensitiveActionExecution(action, wallet: wallet, grant: grant)
  }

  private func beginSensitiveActionExecution(
    _ action: WalletSensitiveAction,
    wallet: ManagedWallet,
    grant: WalletAuthenticationGrant
  ) {
    guard !isAccessingWalletSecret else { return }
    isAccessingWalletSecret = true
    secretAccessTask = Task { @MainActor in
      defer {
        isAccessingWalletSecret = false
        secretAccessTask = nil
      }
      do {
        try await executeSensitiveAction(
          action,
          wallet: wallet,
          grant: grant
        )
      } catch is CancellationError {
      } catch {
        handleSensitiveActionFailure(error, action: action)
      }
    }
  }

  @MainActor
  private func executeSensitiveAction(
    _ action: WalletSensitiveAction,
    wallet: ManagedWallet,
    grant: WalletAuthenticationGrant
  ) async throws {
    try await WalletAuthenticationPresentationReadiness().wait()
    let authorization = try await database.authorizeSecretExport(
      walletID: wallet.id,
      authenticationGrant: grant
    )

    switch action {
    case .viewRecoveryPhrase, .manualBackup:
      let material = try await database.sensitiveMaterial(
        walletID: wallet.id,
        authorization: authorization
      )
      try Task.checkCancellation()
      materialPresentation = WalletSensitiveMaterialPresentation(
        action: action,
        material: material
      )
    case .privateKeyExport:
      let items = try await database.privateKeyExportItems(
        walletID: wallet.id,
        authorization: authorization
      )
      try Task.checkCancellation()
      guard !items.isEmpty else {
        throw WalletManagementError.secretUnavailable
      }
      privateKeyItems = items
      isPrivateKeyExportPresented = true
    case .disableICloudBackup:
      isUpdatingICloudBackup = true
      defer {
        isUpdatingICloudBackup = false
      }
      try await WalletAutomaticCloudBackupService.shared
        .removeBackup(
          walletID: wallet.iCloudBackupWalletID ?? wallet.id
        )
      try await database.clearICloudBackupRemoteVerification(
        walletID: wallet.id
      )
      self.wallet = try await database.managedWallet(
        walletID: wallet.id
      )
      isICloudBackupEnabled = false
      UniHaptic.play(.successQuiet)
      onWalletChanged()
    }
  }

  @MainActor
  private func handleSensitiveActionFailure(
    _ error: Error,
    action: WalletSensitiveAction
  ) {
    if error is CancellationError {
      return
    }
    if let backupError = error.walletCloudBackupCategory,
      backupError == .passkeyCanceled
    {
      isICloudBackupEnabled =
        wallet?.iCloudBackupUpdatedAt != nil
      return
    }

    switch action {
    case .privateKeyExport:
      operationFailure = WalletOperationFailurePresentation(
        messageKey: "settings.wallets.private_key.export.load.error",
        error: error
      )
    case .disableICloudBackup:
      isICloudBackupEnabled =
        wallet?.iCloudBackupUpdatedAt != nil
      operationFailure = WalletOperationFailurePresentation(
        messageKey: iCloudBackupErrorKey(
          for: error,
          enabling: false
        ),
        error: error
      )
    case .viewRecoveryPhrase, .manualBackup:
      operationFailure = WalletOperationFailurePresentation(
        messageKey: "settings.wallets.secret.error",
        error: error
      )
    }
    UniHaptic.play(.error)
  }

  @MainActor
  private func loadWalletAsync() async {
    isLoading = wallet == nil
    errorKey = nil
    do {
      let loadedWallet = try await database.managedWallet(
        walletID: walletID
      )
      wallet = loadedWallet
      isICloudBackupEnabled =
        loadedWallet.iCloudBackupUpdatedAt != nil

      let reconciledWallet = await WalletICloudBackupReconciliation
        .refresh(database: database, wallet: loadedWallet)
      try Task.checkCancellation()
      wallet = reconciledWallet
      isICloudBackupEnabled =
        reconciledWallet.iCloudBackupUpdatedAt != nil
      isLoading = false
    } catch {
      if error is CancellationError { return }
      errorKey = "settings.wallets.details.load.error"
      isLoading = false
    }
  }

  private func iCloudBackupBinding(
    wallet: ManagedWallet
  ) -> Binding<Bool> {
    Binding(
      get: { isICloudBackupEnabled },
      set: { enabled in
        guard enabled != isICloudBackupEnabled,
          !isUpdatingICloudBackup
        else { return }
        if enabled {
          requestICloudBackupEnable(wallet: wallet)
        } else {
          requestSensitiveAction(
            .disableICloudBackup,
            wallet: wallet
          )
        }
      }
    )
  }

  private func requestICloudBackupEnable(
    wallet: ManagedWallet
  ) {
    guard !isAccessingWalletSecret,
      !isUpdatingICloudBackup
    else { return }

    isAccessingWalletSecret = true
    secretAccessTask = Task { @MainActor in
      defer {
        isAccessingWalletSecret = false
        secretAccessTask = nil
      }

      do {
        try await createICloudBackup(wallet: wallet)
      } catch is CancellationError {
      } catch {
        handleICloudBackupEnableFailure(error)
      }
    }
  }

  @MainActor
  private func createICloudBackup(
    wallet: ManagedWallet
  ) async throws {
    isUpdatingICloudBackup = true
    defer {
      isUpdatingICloudBackup = false
    }

    try await WalletICloudPasskeyBackupCreation.create(
      database: database,
      wallet: wallet,
      presentationAnchor: passkeyPresentationWindow
    )
    isICloudBackupEnabled = true
    self.wallet = try await database.managedWallet(
      walletID: wallet.id
    )
    UniHaptic.play(.successQuiet)
    onWalletChanged()
  }

  @MainActor
  private func handleICloudBackupEnableFailure(_ error: Error) {
    isICloudBackupEnabled = wallet?.iCloudBackupUpdatedAt != nil
    if error.walletCloudBackupCategory == .passkeyCanceled {
      return
    }

    operationFailure =
      WalletICloudPasskeyBackupCreation.failure(for: error)
    UniHaptic.play(.error)
  }

  private func iCloudBackupErrorKey(
    for error: Error,
    enabling: Bool
  ) -> String {
    guard let backupError = error.walletCloudBackupCategory else {
      return enabling
        ? "settings.wallets.backup.icloud.enable.error"
        : "settings.wallets.backup.icloud.disable.error"
    }
    switch backupError {
    case .iCloudUnavailable:
      return "settings.wallets.backup.icloud.unavailable"
    case .backupKeyUnavailable, .keychainFailure:
      return "settings.wallets.backup.icloud.key.error"
    case .storageFailed:
      return "settings.wallets.backup.icloud.drive.error"
    case .remoteVerificationFailed:
      return "settings.wallets.backup.icloud.verification.error"
    default:
      return enabling
        ? "settings.wallets.backup.icloud.enable.error"
        : "settings.wallets.backup.icloud.disable.error"
    }
  }
}
