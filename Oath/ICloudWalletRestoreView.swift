import SwiftUI

struct ICloudWalletRestoreView: View {
  let database: WalletDatabase
  let onRestore: (
    WalletImportDraft,
    String,
    WalletCloudBackupRemoteIdentity
  ) -> Void

  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var discovery: ICloudWalletRestoreDiscoveryModel
  @State private var editMode: EditMode = .inactive
  @State private var selectedWalletIDs = Set<String>()
  @State private var deletionRequest: ICloudWalletBackupDeletionRequest?
  @State private var deletionFailure: ICloudWalletBackupDeletionFailure?
  @State private var isDeleting = false
  @State private var isPreparingDeletionAuthentication = false
  @State private var deletionAuthenticationContext:
    WalletAuthenticationPasscodeContext?
  @State private var deletionAuthenticationWalletIDs = Set<String>()
  @State private var isDeletionAuthenticationPresented = false
  @State private var deletesAfterAuthentication = false
  @State private var deletionAuthenticationFailurePresented = false

  init(
    database: WalletDatabase,
    discovery: ICloudWalletRestoreDiscoveryModel = .init(),
    onRestore: @escaping (
      WalletImportDraft,
      String,
      WalletCloudBackupRemoteIdentity
    ) -> Void
  ) {
    self.database = database
    self.onRestore = onRestore
    _discovery = State(initialValue: discovery)
  }

  var body: some View {
    lifecycleContent
  }

  private var restoreList: some View {
    List(selection: $selectedWalletIDs) {
        Group {
          backupSection
        }
        .walletListRowSurface()
    }
    .walletListAppearance()
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(WalletTheme.groupedBackground)
    .navigationTitle("import.icloud.navigation.title")
    .navigationBarTitleDisplayMode(.inline)
    .environment(\.editMode, $editMode)
  }

  private var toolbarContent: some View {
    restoreList
      .toolbar {
        ToolbarItem(placement: .principal) {
          Text("import.icloud.navigation.title")
            .font(WalletTypography.sheetTitle)
            .foregroundStyle(WalletTheme.primaryLabel)
            .lineLimit(1)
            .accessibilityIdentifier("icloud.restore.title")
        }

        if showsSelectionControls {
          if editMode.isEditing {
            ToolbarItem(placement: .confirmationAction) {
              WalletConfirmationButton {
                toggleEditing()
              }
              .disabled(isDeletionBusy)
              .accessibilityIdentifier("icloud.restore.select")
            }
          } else {
            ToolbarItem(placement: .topBarTrailing) {
              Button("selection.select", action: UniHaptic.action {
                toggleEditing()
              })
              .disabled(isDeletionBusy)
              .accessibilityIdentifier("icloud.restore.select")
            }
          }
        }

        if editMode.isEditing {
          ToolbarItem(placement: .topBarLeading) {
            Button(
              allBackupsAreSelected
                ? "import.icloud.selection.deselect_all"
                : "import.icloud.selection.select_all"
            , action: UniHaptic.action {
              toggleSelectAll()
            })
            .disabled(isDeletionBusy)
            .accessibilityIdentifier("icloud.restore.selectAll")
          }

          ToolbarItemGroup(placement: .bottomBar) {
            Spacer()

            Button(role: .destructive, action: UniHaptic.action {
              requestDeletion(of: selectedWalletIDs)
            }) {
              Label {
                Text(verbatim: selectedDeletionTitle)
              } icon: {
                Image(systemName: "trash")
              }
            }
            .labelStyle(.titleAndIcon)
            .disabled(
              selectedWalletIDs.isEmpty || isDeletionBusy
            )
            .accessibilityIdentifier("icloud.restore.delete")
          }
        }
      }
  }

  private var dialogContent: some View {
    toolbarContent
      .alert(
        Text(
          verbatim:
            deletionRequest?.confirmationTitle ?? ""
        ),
        isPresented: deletionRequestBinding
      ) {
        if let deletionRequest {
          Button(role: .destructive, action: UniHaptic.action {
            prepareDeletion(
              deletionRequest.walletIDs
            )
          }) {
            Text(verbatim: deletionRequest.actionTitle)
          }
        }

        Button("common.cancel", role: .cancel, action: UniHaptic.action {})
      } message: {
        Text("import.icloud.delete.confirm.message")
      }
      .alert(
        "import.icloud.delete.error.title",
        isPresented: deletionFailureBinding
      ) {
        Button("common.done", role: .cancel, action: UniHaptic.action {})
      } message: {
        if let deletionFailure {
          Text(verbatim: deletionFailure.message)
        }
      }
      .alert(
        "import.icloud.delete.authentication.error.title",
        isPresented: $deletionAuthenticationFailurePresented
      ) {
        Button("common.done", role: .cancel, action: UniHaptic.action {})
      } message: {
        Text("import.icloud.delete.authentication.error.message")
      }
      .fullScreenCover(
        isPresented: $isDeletionAuthenticationPresented,
        onDismiss: deletionAuthenticationDidDismiss
      ) {
        if let context = deletionAuthenticationContext {
          WalletAuthenticationFullScreenContainer(
            title:
              "security.authentication.navigation_title"
          ) {
            ICloudBackupDeletionAuthenticationScreen(
              database: database,
              context: context
            ) {
              deletesAfterAuthentication = true
              isDeletionAuthenticationPresented = false
            }
          }
        }
      }
  }

  private var lifecycleContent: some View {
    dialogContent
      .interactiveDismissDisabled(isDeletionBusy)
      .task {
        discovery.start()
      }
      .onDisappear {
        discovery.stop()
      }
      .onChange(of: scenePhase) { _, newPhase in
        guard newPhase == .active else { return }
        discovery.refreshAfterForeground()
      }
      .onChange(of: discovery.backupWalletIDs) { _, walletIDs in
        selectedWalletIDs.formIntersection(walletIDs)
        if walletIDs.isEmpty {
          editMode = .inactive
        }
      }
  }

  private var backupSection: some View {
    Section {
      backupSectionRows
    } header: {
      Text("import.icloud.section")
    } footer: {
      Text("import.icloud.keychain.footer")
    }
  }

  @ViewBuilder
  private var backupSectionRows: some View {
    if discovery.isLoading {
      Text("import.icloud.loading")
        .foregroundStyle(.secondary)
    } else if let loadFailure = discovery.loadFailure {
      VStack(alignment: .leading, spacing: 12) {
        Text(loadFailure.message)
          .foregroundStyle(.secondary)

        Button("settings.wallets.load.retry", action: UniHaptic.action {
          discovery.retry()
        })
      }
    } else if discovery.backups.isEmpty {
      WalletEmptyStateView(
        "import.icloud.empty.title",
        message: "import.icloud.empty.message"
      )
    } else {
      ForEach(
        discovery.backups
      ) { backup in
        backupListRow(backup: backup)
      }
    }
  }

  private func backupListRow(
    backup: WalletCloudBackupDescriptor
  ) -> some View {
    // A stable row container preserves List's native selection animation.
    // Editing uses a label: navigation links are disabled and dimmed by iOS.
    VStack(alignment: .leading, spacing: 0) {
      if editMode.isEditing {
        backupRow(backup: backup)
          .accessibilityElement(children: .combine)
      } else {
        NavigationLink {
            Group {
              ICloudWalletAutomaticRestoreView(
                walletID: backup.walletID,
                walletName: backup.walletName,
                backedUpAt: backup.backedUpAt,
                hasPassphrase: backup.hasPassphrase,
                onRestore: onRestore
              )
            }

        } label: {
          backupRow(backup: backup)
        }
      }
    }
    .tag(backup.walletID)
    .accessibilityIdentifier("icloud.restore.backup.\(backup.walletID)")
    .swipeActions(
      edge: .trailing,
      allowsFullSwipe: true
    ) {
      if !editMode.isEditing {
        Button(role: .destructive, action: UniHaptic.action {
          requestDeletion(of: [backup.walletID])
        }) {
          Label("import.icloud.delete.action", systemImage: "trash")
        }
      }
    }
  }

  private func backupRow(
    backup: WalletCloudBackupDescriptor
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(
        verbatim: backup.walletName
          ?? WalletLocalization.string(
            "import.icloud.backup.title"
          )
      )
      .font(.headline)
      .foregroundStyle(WalletTheme.primaryLabel)

      if let backedUpAt = backup.backedUpAt {
        Text(
          verbatim: EnglishNumbers.localized(
            "settings.wallets.backup.icloud.last_successful",
            EnglishNumbers.dateTime(backedUpAt)
          )
        )
        .font(.caption)
        .foregroundStyle(WalletTheme.secondaryLabel)
      }
    }
    .padding(.vertical, 3)
  }

  private var showsSelectionControls: Bool {
    editMode.isEditing
      || (!discovery.isLoading
        && discovery.loadFailure == nil
        && !discovery.backupWalletIDs.isEmpty)
  }

  private var allBackupsAreSelected: Bool {
    !discovery.backupWalletIDs.isEmpty
      && selectedWalletIDs
        == Set(discovery.backupWalletIDs)
  }

  private var selectedDeletionTitle: String {
    deletionActionTitle(count: selectedWalletIDs.count)
  }

  private var deletionFailureBinding: Binding<Bool> {
    Binding(
      get: { deletionFailure != nil },
      set: { isPresented in
        if !isPresented {
          deletionFailure = nil
        }
      }
    )
  }

  private var deletionRequestBinding: Binding<Bool> {
    Binding(
      get: { deletionRequest != nil },
      set: { isPresented in
        if !isPresented {
          deletionRequest = nil
        }
      }
    )
  }

  private func toggleEditing() {
    withAnimation(reduceMotion ? nil : .default) {
      if editMode.isEditing {
        editMode = .inactive
        selectedWalletIDs.removeAll()
      } else {
        editMode = .active
      }
    }
  }

  private func toggleSelectAll() {
    withAnimation(reduceMotion ? nil : .default) {
      if allBackupsAreSelected {
        selectedWalletIDs.removeAll()
      } else {
        selectedWalletIDs = Set(
          discovery.backupWalletIDs
        )
      }
    }
  }

  private func requestDeletion(
    of walletIDs: Set<String>
  ) {
    guard !walletIDs.isEmpty, !isDeletionBusy else { return }
    deletionRequest = ICloudWalletBackupDeletionRequest(
      walletIDs: walletIDs
    )
  }

  private var isDeletionBusy: Bool {
    isDeleting || isPreparingDeletionAuthentication
      || deletionAuthenticationContext != nil
  }

  private func prepareDeletion(_ walletIDs: Set<String>) {
    guard !walletIDs.isEmpty, !isDeletionBusy else { return }
    isPreparingDeletionAuthentication = true
    deletionAuthenticationFailurePresented = false

    Task { @MainActor in
      defer { isPreparingDeletionAuthentication = false }
      do {
        let settings =
          try await database
          .walletSecuritySettings()

        switch ICloudBackupDeletionAuthorizationPolicy
          .decision(settings: settings)
        {
        case .deleteWithoutAuthentication:
          deleteBackups(walletIDs)
        case .authenticate:
          switch await WalletAuthenticationAction.prepare(
            settings: settings,
            purpose: .deleteICloudBackup
          ) {
          case .authorized:
            deleteBackups(walletIDs)
          case let .requiresPasscode(context):
            deletionAuthenticationWalletIDs = walletIDs
            deletionAuthenticationContext = context
            isDeletionAuthenticationPresented = true
          case .cancelled:
            break
          }
        }
      } catch {
        deletionAuthenticationFailurePresented = true
        UniHaptic.play(.error)
      }
    }
  }

  private func deletionAuthenticationDidDismiss() {
    let walletIDs = deletionAuthenticationWalletIDs
    deletionAuthenticationWalletIDs.removeAll()
    deletionAuthenticationContext = nil

    guard deletesAfterAuthentication else { return }
    deletesAfterAuthentication = false
    deleteBackups(walletIDs)
  }

  private func deleteBackups(_ walletIDs: Set<String>) {
    guard !walletIDs.isEmpty, !isDeleting else { return }
    isDeleting = true
    deletionFailure = nil

    Task {
      let outcome =
        await ICloudWalletBackupDeletionExecutor.execute(
          walletIDs: walletIDs,
          deleteRemoteBackup: { walletID in
            try await WalletAutomaticCloudBackupService.shared
              .removeBackup(
                walletID: walletID,
                expectsExistingBackup: true
              )
          },
          clearLocalVerification: { walletID in
            try await database
              .clearICloudBackupRemoteVerification(
                walletID: walletID
              )
          }
        )

      discovery.remove(
        walletIDs: outcome.deletedWalletIDs
      )
      selectedWalletIDs.subtract(
        outcome.deletedWalletIDs
      )
      isDeleting = false

      if let failure = outcome.failure {
        deletionFailure = failure
        UniHaptic.play(.error)
      } else {
        UniHaptic.play(.successQuiet)
      }

      if discovery.backupWalletIDs.isEmpty {
        editMode = .inactive
        selectedWalletIDs.removeAll()
      }
    }
  }

  private func deletionActionTitle(count: Int) -> String {
    if count == 1 {
      return WalletLocalization.string(
        "import.icloud.delete.action"
      )
    }
    return EnglishNumbers.localized(
      "import.icloud.delete.action.multiple",
      Int64(count)
    )
  }
}

private struct ICloudWalletBackupDeletionRequest: Identifiable {
  let walletIDs: Set<String>

  var id: String {
    walletIDs.sorted().joined(separator: "\u{1F}")
  }

  var confirmationTitle: String {
    if walletIDs.count == 1 {
      return WalletLocalization.string(
        "import.icloud.delete.confirm.title"
      )
    }
    return EnglishNumbers.localized(
      "import.icloud.delete.confirm.title.multiple",
      Int64(walletIDs.count)
    )
  }

  var actionTitle: String {
    if walletIDs.count == 1 {
      return WalletLocalization.string(
        "import.icloud.delete.action"
      )
    }
    return EnglishNumbers.localized(
      "import.icloud.delete.action.multiple",
      Int64(walletIDs.count)
    )
  }
}
