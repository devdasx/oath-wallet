import SwiftUI

struct WalletDetailSettingsView: View {
  let database: WalletDatabase
  let walletID: String
  let onWalletSelected: (String) -> Void
  let onWalletRenamed: (String, String) -> Void
  let onWalletAppearanceChanged: (String, WalletAppearanceColor) -> Void
  let onWalletChanged: () -> Void
  let onRemoveWalletRequested: (String) -> Void

  @Environment(\.openURL) private var openURL
  @State private var wallet: ManagedWallet?
  @State private var isLoading = true
  @State private var errorKey: String?
  @State private var walletForColor: ManagedWallet?
  @State private var isRenamePresented = false
  @State private var proposedName = ""
  @State private var operationFailure: WalletOperationFailurePresentation?
  @State private var notificationsEnabledWhenInactive = false
  @State private var isUpdatingWalletNotifications = false
  @State private var isSelectingWallet = false

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
              WalletManagementErrorRow(messageKey: errorKey, onRetry: loadWallet)
            }
          } else if let wallet {
            walletDetailSections(wallet)
          }
        }
        .walletListRowSurface()
    }
    .walletListAppearance()
    .listStyle(.insetGrouped)
    .navigationTitle(wallet?.name ?? "")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $walletForColor, onDismiss: loadWallet) { wallet in
      WalletColorPickerSheet(database: database, wallet: wallet) { color in
        self.wallet?.appearanceColor = color
        onWalletAppearanceChanged(wallet.id, color)
        onWalletChanged()
      }
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }
    .task { await loadWalletAsync() }
    .alert(
      "settings.wallets.rename.title",
      isPresented: $isRenamePresented
    ) {
      TextField(
        "settings.wallets.rename.placeholder",
        text: $proposedName
      )
      .walletTextInputDirection()
      Button("settings.wallets.rename.save", action: UniHaptic.action {
        renameWallet()
      })
      Button("common.cancel", role: .cancel, action: UniHaptic.action {})
    } message: {
      Text("settings.wallets.rename.message")
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

  @ViewBuilder
  private func walletDetailSections(_ wallet: ManagedWallet) -> some View {
    Section("settings.wallets.details.section") {
      Button(action: UniHaptic.action(nil) { beginRenaming(wallet) }) {
        LabeledContent {
          HStack(spacing: 8) {
            Text(wallet.name)
              .foregroundStyle(WalletTheme.secondaryLabel)
              .lineLimit(1)
            Image(systemName: "chevron.forward")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(WalletTheme.tertiaryLabel)
              .accessibilityHidden(true)
          }
        } label: {
          Text("settings.wallets.details.name")
            .foregroundStyle(WalletTheme.primaryLabel)
        }
        .contentShape(Rectangle())
      }
      .accessibilityHint(Text("settings.wallets.rename.message"))
      LabeledContent("settings.wallets.details.added") {
        Text(verbatim: EnglishNumbers.transactionDateTime(wallet.createdAt))
          .foregroundStyle(WalletTheme.secondaryLabel)
          .multilineTextAlignment(.trailing)
      }
    }

    Section("settings.wallets.management.section") {
      Toggle(isOn: Binding(
        get: { wallet.isSelected },
        set: { enabled in if enabled { selectWallet() } }
      )) {
        Text("settings.wallets.status")
          .foregroundStyle(WalletTheme.primaryLabel)
      }
      // One wallet must remain selected. Activate a different wallet to switch.
      .disabled(wallet.isSelected || isSelectingWallet)
      .accessibilityIdentifier("walletDetailsActiveToggle")

      Button(action: UniHaptic.action(nil) { walletForColor = wallet }) {
        LabeledContent {
          WalletIdentityIcon(color: wallet.appearanceColor, placement: .toolbar)
        } label: {
          Text("settings.wallets.color.change")
            .foregroundStyle(WalletTheme.primaryLabel)
        }
        .contentShape(Rectangle())
        .accessibilityValue(Text(wallet.appearanceColor.nameKey))
      }
    }

    Section {
      Toggle(isOn: Binding(
        get: { notificationsEnabledWhenInactive },
        set: { updateInactiveWalletNotifications($0) }
      )) {
        Text("settings.wallets.notifications.inactive")
          .foregroundStyle(WalletTheme.primaryLabel)
      }
      .disabled(isUpdatingWalletNotifications)
      .accessibilityIdentifier("walletDetailsInactiveNotifications")
    } header: {
      Text("settings.notifications.title")
    } footer: {
      Text("settings.wallets.notifications.inactive.footer")
    }

    if wallet.kind.hasExportableSecret {
      Section {
        NavigationLink {
          WalletBackupSettingsView(database: database, walletID: wallet.id, onWalletChanged: onWalletChanged)
        } label: {
          SettingsRowTitle(title: "settings.wallets.backup.wallet", icon: .walletBackup)
        }
        .accessibilityIdentifier("walletDetailsBackup")
      } footer: {
        Text("settings.wallets.backup.wallet.footer")
      }
    }

    Section {
      Button(action: UniHaptic.action { onRemoveWalletRequested(wallet.id) }) {
        Label {
          Text("settings.wallets.remove")
            .foregroundStyle(WalletTheme.danger)
        } icon: {
          SettingsIconTile(icon: .walletRemoval)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.automatic)
    } footer: {
      Text("settings.wallets.remove.footer")
    }
  }

  private func beginRenaming(_ wallet: ManagedWallet) {
    proposedName = wallet.name
    isRenamePresented = true
  }
  private func loadWallet() {
    Task {
      await loadWalletAsync()
    }
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
      notificationsEnabledWhenInactive =
        loadedWallet.notificationsEnabledWhenInactive

      let reconciledWallet = await WalletICloudBackupReconciliation
        .refresh(database: database, wallet: loadedWallet)
      try Task.checkCancellation()
      wallet = reconciledWallet
      isLoading = false
    } catch {
      if error is CancellationError { return }
      errorKey = "settings.wallets.details.load.error"
      isLoading = false
    }
  }
  private func renameWallet() {
    Task {
      do {
        let renamedWallet = try await database.renameWallet(
          walletID: walletID,
          name: proposedName
        )
        await MainActor.run {
          wallet = renamedWallet
          proposedName = renamedWallet.name
          onWalletRenamed(
            renamedWallet.address,
            renamedWallet.name
          )
          UniHaptic.play(.successQuiet)
        }
        onWalletChanged()
      } catch {
        await MainActor.run {
          operationFailure = WalletOperationFailurePresentation(
            messageKey: "settings.wallets.rename.error",
            error: error
          )
          UniHaptic.play(.error)
        }
      }
    }
  }
  private func selectWallet() {
    guard !isSelectingWallet, wallet?.isSelected == false else { return }
    isSelectingWallet = true
    Task {
      defer { isSelectingWallet = false }
      do {
        let identity = try await database.selectWallet(
          walletID: walletID
        )
        wallet = try await database.managedWallet(walletID: walletID)
        PushNotificationCoordinator.shared.walletDataDidChange()
        onWalletSelected(identity.address)
      } catch {
        operationFailure = WalletOperationFailurePresentation(
          messageKey: "settings.wallets.select.error",
          error: error
        )
      }
    }
  }
  private func updateInactiveWalletNotifications(_ enabled: Bool) {
    guard !isUpdatingWalletNotifications else { return }
    let previous = notificationsEnabledWhenInactive
    notificationsEnabledWhenInactive = enabled
    isUpdatingWalletNotifications = true

    Task {
      do {
        let updated =
          try await database
          .setNotificationsEnabledWhenInactive(
            walletID: walletID,
            enabled: enabled
          )
        await MainActor.run {
          wallet = updated
          notificationsEnabledWhenInactive =
            updated.notificationsEnabledWhenInactive
          isUpdatingWalletNotifications = false
          UniHaptic.play(.successQuiet)
        }
        PushNotificationCoordinator.shared.walletDataDidChange()
        onWalletChanged()
      } catch {
        await MainActor.run {
          notificationsEnabledWhenInactive = previous
          isUpdatingWalletNotifications = false
          operationFailure = WalletOperationFailurePresentation(
            messageKey: "settings.wallets.notifications.update.error",
            error: error
          )
          UniHaptic.play(.error)
        }
      }
    }
  }
}
