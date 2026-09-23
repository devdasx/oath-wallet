import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Aperture

@Suite(.serialized)
struct ICloudWalletBackupDeletionTests {
  @Test
  func everyWalletUsesAStableUniquePasskeyUserHandle() {
    let first = WalletBackupPasskeyIdentity.userHandle(
      walletID: "wallet-a"
    )
    let same = WalletBackupPasskeyIdentity.userHandle(
      walletID: "wallet-a"
    )
    let second = WalletBackupPasskeyIdentity.userHandle(
      walletID: "wallet-b"
    )

    #expect(first.count == 32)
    #expect(first == same)
    #expect(first != second)
  }

  @Test
  @MainActor
  func userInitiatedBackupDoesNotReadMaterialBeforePasskeyApproval()
    async throws
  {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let walletID = "passkey-first-\(UUID().uuidString)"
    let service = WalletAutomaticCloudBackupService(
      passkeyAuthorizer:
        ICloudBackupCancelingPasskeyAuthorizerProbe(),
      dataKeyStore: ICloudBackupDataKeyStoreProbe(),
      documentStore: WalletICloudDriveBackupStore(
        containerURLProvider: { root }
      )
    )
    let wallet = ManagedWallet(
      id: walletID,
      name: "Passkey First Wallet",
      kind: .created,
      address: "0x0000000000000000000000000000000000000001",
      fiatUSDBalance: 0,
      isSelected: true,
      notificationsEnabledWhenInactive: false,
      backupState: .notVerified,
      backupVerifiedAt: nil,
      iCloudBackupUpdatedAt: nil,
      mnemonicWordCount: 12,
      createdAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
    let materialProbe = ICloudBackupMaterialRequestProbe()

    await #expect(throws: WalletCloudBackupError.passkeyCanceled) {
      _ = try await service.backup(
        wallet: wallet,
        privateKeyMetadata: nil
      ) { authorization in
        materialProbe.material(
          authorization: authorization,
          walletID: walletID
        )
      }
    }

    #expect(materialProbe.requestCount == 0)
  }

  @Test
  func automaticBackupEncryptsVerifiesRestoresAndRemoves()
    async throws
  {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let walletID = "automatic-backup-\(UUID().uuidString)"
    let passkeyAuthorizer = ICloudBackupPasskeyAuthorizerProbe()
    let dataKeyStore = ICloudBackupDataKeyStoreProbe()
    let store = WalletICloudDriveBackupStore(
      containerURLProvider: { root }
    )
    let service = WalletAutomaticCloudBackupService(
      passkeyAuthorizer: passkeyAuthorizer,
      dataKeyStore: dataKeyStore,
      documentStore: store
    )
    let phrase =
      "abandon abandon abandon abandon abandon "
      + "abandon abandon abandon abandon abandon abandon about"
    let credential = try WalletRecoveryCredential(
      mnemonic: phrase,
      passphrase: "test-only passphrase"
    )
    let expectedDraft = try WalletCoreService.importRecoveryPhrase(
      credential.mnemonic,
      passphrase: credential.passphrase
    )
    let wallet = ManagedWallet(
      id: walletID,
      name: "Automatic Backup Wallet",
      kind: .created,
      address: expectedDraft.address,
      fiatUSDBalance: 0,
      isSelected: true,
      notificationsEnabledWhenInactive: false,
      backupState: .notVerified,
      backupVerifiedAt: nil,
      iCloudBackupUpdatedAt: nil,
      mnemonicWordCount: 12,
      createdAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
    let material = WalletSensitiveMaterial.recoveryPhrase(credential)
    let receipt = try await service.backup(
      wallet: wallet,
      privateKeyMetadata: nil
    ) { authorization in
      #expect(authorization.permits(walletID: walletID))
      #expect(
        passkeyAuthorizer.registeredWalletIDs() == [walletID]
      )
      return material
    }
    #expect(!receipt.serverChangeTag.isEmpty)

    let currentReceipt = try await service.backup(
      wallet: wallet,
      material: material,
      privateKeyMetadata: nil
    )
    #expect(
      await passkeyAuthorizer.registeredWalletIDs() == [walletID]
    )
    #expect(await passkeyAuthorizer.assertedWalletIDs().isEmpty)

    let descriptors = try await service.availableBackups()
    #expect(descriptors.count == 1)
    #expect(descriptors.first?.walletID == walletID)
    #expect(descriptors.first?.walletName == wallet.name)
    #expect(descriptors.first?.backedUpAt != nil)
    #expect(descriptors.first?.hasPassphrase == true)

    let restoreResult = try await service.restoreResult(
      walletID: walletID
    )
    let restored = restoreResult.payload
    #expect(restoreResult.remoteIdentity.walletID == walletID)
    #expect(
      restoreResult.remoteIdentity.receipt.serverChangeTag
        == currentReceipt.serverChangeTag
    )
    #expect(restored.walletName == wallet.name)
    #expect(restored.walletKind == wallet.kind.rawValue)
    #expect(restored.address == wallet.address)
    let encodedMaterial = try material.encodedData()
    #expect(restored.secret == encodedMaterial)
    let restoredCredential = try WalletRecoveryCredential.decode(
      restored.secret
    )
    #expect(restoredCredential == credential)
    #expect(restored.hasPassphrase == true)
    let validated = try ICloudWalletRestoreValidator.validate(restored)
    #expect(validated.draft == expectedDraft)
    #expect(validated.walletName == wallet.name)
    #expect(
      await passkeyAuthorizer.registeredWalletIDs() == [walletID]
    )
    #expect(
      await passkeyAuthorizer.assertedWalletIDs() == [walletID]
    )
    #expect(await dataKeyStore.contains(walletID: walletID))

    // Affected releases assigned a fresh local UUID after restoring this
    // remote document. Reconciliation must recover the real cloud identity
    // from the authorized data-key cache and the decrypted wallet address.
    let restoredLocalWallet = ManagedWallet(
      id: "restored-local-\(UUID().uuidString)",
      name: "Restored Wallet",
      kind: .importedRecoveryPhrase,
      address: expectedDraft.address,
      fiatUSDBalance: 0,
      isSelected: true,
      notificationsEnabledWhenInactive: false,
      backupState: .notVerified,
      backupVerifiedAt: nil,
      iCloudBackupUpdatedAt: nil,
      mnemonicWordCount: 12,
      createdAt: Date(timeIntervalSince1970: 2_000_000_200)
    )
    let repairedIdentity = try await service.verifiedBackup(
      for: restoredLocalWallet
    )
    #expect(repairedIdentity.walletID == walletID)
    #expect(!repairedIdentity.receipt.serverChangeTag.isEmpty)

    var linkedLocalWallet = restoredLocalWallet
    linkedLocalWallet.iCloudBackupWalletID = walletID
    let linkedIdentity = try await service.verifiedBackup(
      for: linkedLocalWallet
    )
    #expect(linkedIdentity.walletID == walletID)
    #expect(linkedIdentity.receipt == repairedIdentity.receipt)

    try await service.removeBackup(
      walletID: walletID,
      expectsExistingBackup: true
    )
    #expect(try await service.availableBackups().isEmpty)
    #expect(!(await dataKeyStore.contains(walletID: walletID)))
    await #expect(throws: WalletCloudBackupError.backupNotFound) {
      _ = try await service.restore(walletID: walletID)
    }
  }

  @Test
  func restoreValidatorUsesTheEncryptedPassphraseAndChecksMetadata()
    throws
  {
    let credential = try WalletRecoveryCredential(
      mnemonic:
        "abandon abandon abandon abandon abandon "
        + "abandon abandon abandon abandon abandon abandon about",
      passphrase: "test-only passphrase"
    )
    let expectedDraft = try WalletCoreService.importRecoveryPhrase(
      credential.mnemonic,
      passphrase: credential.passphrase
    )
    let encodedCredential = try credential.encodedData()
    let legacyPayload = WalletCloudBackupPayload(
      version: 3,
      walletName: "Legacy Passphrase Wallet",
      walletKind: ManagedWalletKind.created.rawValue,
      address: expectedDraft.address,
      secret: encodedCredential,
      hasPassphrase: nil,
      privateKeyNetwork: nil,
      privateKeyFormat: nil,
      createdAt: 2_000_000_000,
      backedUpAt: 2_000_000_100
    )

    let restored = try ICloudWalletRestoreValidator.validate(
      legacyPayload
    )
    #expect(restored.draft == expectedDraft)

    let mismatchedPayload = WalletCloudBackupPayload(
      version: legacyPayload.version,
      walletName: legacyPayload.walletName,
      walletKind: legacyPayload.walletKind,
      address: legacyPayload.address,
      secret: legacyPayload.secret,
      hasPassphrase: false,
      privateKeyNetwork: nil,
      privateKeyFormat: nil,
      createdAt: legacyPayload.createdAt,
      backedUpAt: legacyPayload.backedUpAt
    )
    #expect(throws: WalletCloudBackupError.decryptionFailed) {
      _ = try ICloudWalletRestoreValidator.validate(
        mismatchedPayload
      )
    }
  }

  @Test
  func automaticDriveDocumentRoundTripsUpdatesAndDeletes()
    async throws
  {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let store = WalletICloudDriveBackupStore(
      containerURLProvider: { root }
    )
    let walletID = "automatic-drive-round-trip-wallet"
    let originalPayload = Data("first encrypted payload".utf8)
    let credentialID = Data(repeating: 0x21, count: 32)
    let prfSalt = Data(repeating: 0x43, count: 32)
    let wrappedDataKey = Data(repeating: 0x32, count: 60)
    let original = WalletICloudDriveBackupDocument(
      version: WalletICloudDriveBackupDocument.currentVersion,
      algorithm: WalletICloudDriveBackupDocument.algorithm,
      walletID: walletID,
      walletName: "Savings Wallet",
      hasPassphrase: nil,
      applicationName: "Aperture",
      passkeyCredentialID: credentialID,
      passkeyPRFSalt: prfSalt,
      wrappedDataKey: wrappedDataKey,
      encryptedPayload: originalPayload,
      contentDigest: WalletICloudDriveBackupDocument.digest(
        walletID: walletID,
        walletName: "Savings Wallet",
        applicationName: "Aperture",
        passkeyCredentialID: credentialID,
        passkeyPRFSalt: prfSalt,
        wrappedDataKey: wrappedDataKey,
        encryptedPayload: originalPayload
      ),
      createdAt: 2_000_000_000,
      modifiedAt: 2_000_000_100
    )

    let saved = try await store.save(original)
    #expect(saved == original)
    #expect(try await store.fetch(walletID: walletID) == original)
    #expect(try await store.availableDocuments() == [original])

    let updatedPayload = Data("updated encrypted payload".utf8)
    let updated = WalletICloudDriveBackupDocument(
      version: WalletICloudDriveBackupDocument.currentVersion,
      algorithm: WalletICloudDriveBackupDocument.algorithm,
      walletID: walletID,
      walletName: "Renamed Savings Wallet",
      hasPassphrase: true,
      applicationName: "Aperture",
      passkeyCredentialID: credentialID,
      passkeyPRFSalt: prfSalt,
      wrappedDataKey: wrappedDataKey,
      encryptedPayload: updatedPayload,
      contentDigest: WalletICloudDriveBackupDocument.digest(
        walletID: walletID,
        walletName: "Renamed Savings Wallet",
        hasPassphrase: true,
        applicationName: "Aperture",
        passkeyCredentialID: credentialID,
        passkeyPRFSalt: prfSalt,
        wrappedDataKey: wrappedDataKey,
        encryptedPayload: updatedPayload
      ),
      createdAt: original.createdAt,
      modifiedAt: original.modifiedAt + 10
    )

    _ = try await store.save(updated)
    #expect(try await store.availableDocuments() == [updated])
    #expect(try await store.remove(walletID: walletID))
    #expect(try await store.availableDocuments().isEmpty)
    #expect(!(try await store.remove(walletID: walletID)))
  }

  @Test
  func automaticDriveDocumentRejectsAnInvalidDigest() async {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let store = WalletICloudDriveBackupStore(
      containerURLProvider: { root }
    )
    let invalid = WalletICloudDriveBackupDocument(
      version: WalletICloudDriveBackupDocument.currentVersion,
      algorithm: WalletICloudDriveBackupDocument.algorithm,
      walletID: "invalid-drive-document-wallet",
      walletName: "Wallet",
      hasPassphrase: false,
      applicationName: "Aperture",
      passkeyCredentialID: Data(repeating: 0x65, count: 32),
      passkeyPRFSalt: Data(repeating: 0x87, count: 32),
      wrappedDataKey: Data(repeating: 0x76, count: 60),
      encryptedPayload: Data([1, 2, 3]),
      contentDigest: WalletICloudDriveBackupDocument.digest(
        walletID: "invalid-drive-document-wallet",
        walletName: "Wallet",
        hasPassphrase: true,
        applicationName: "Aperture",
        passkeyCredentialID: Data(repeating: 0x65, count: 32),
        passkeyPRFSalt: Data(repeating: 0x87, count: 32),
        wrappedDataKey: Data(repeating: 0x76, count: 60),
        encryptedPayload: Data([1, 2, 3])
      ),
      createdAt: 2_000_000_000,
      modifiedAt: 2_000_000_100
    )

    await #expect(
      throws: WalletCloudBackupError.invalidBackupDocument
    ) {
      _ = try await store.save(invalid)
    }
  }

  @Test
  func batchDeletionStopsAtFirstStorageFailureAndKeepsRemainder()
    async
  {
    let recorder = ICloudBackupDeletionRecorder(
      storageFailureWalletID: "wallet-b"
    )

    let outcome =
      await ICloudWalletBackupDeletionExecutor.execute(
        walletIDs: ["wallet-c", "wallet-a", "wallet-b"],
        deleteRemoteBackup: { walletID in
          try await recorder.deleteRemote(walletID)
        },
        clearLocalVerification: { walletID in
          try await recorder.clearLocal(walletID)
        }
      )
    let calls = await recorder.calls()

    #expect(outcome.deletedWalletIDs == ["wallet-a"])
    #expect(
      outcome.remainingWalletIDs
        == ["wallet-b", "wallet-c"]
    )
    #expect(outcome.failure == .storageVerification)
    #expect(calls.remote == ["wallet-a", "wallet-b"])
    #expect(calls.local == ["wallet-a"])
  }

  @Test
  func localMarkerFailureDoesNotMisreportCloudBackupAsPresent()
    async
  {
    let recorder = ICloudBackupDeletionRecorder(
      localFailureWalletID: "wallet-b"
    )

    let outcome =
      await ICloudWalletBackupDeletionExecutor.execute(
        walletIDs: ["wallet-a", "wallet-b", "wallet-c"],
        deleteRemoteBackup: { walletID in
          try await recorder.deleteRemote(walletID)
        },
        clearLocalVerification: { walletID in
          try await recorder.clearLocal(walletID)
        }
      )

    #expect(
      outcome.deletedWalletIDs
        == ["wallet-a", "wallet-b"]
    )
    #expect(outcome.remainingWalletIDs == ["wallet-c"])
    #expect(outcome.failure == .localMetadata)
  }

  @Test
  func clearingBackupStatusPreservesTheLiveWalletSecretReference()
    async throws
  {
    let database = try WalletDatabase.temporary()
    let walletID = "local-wallet-with-icloud-backup"
    let cloudWalletID = "remote-wallet-in-icloud"
    let secretReference = "device-only-live-wallet-secret"
    try await database.pool.write { database in
      var wallet = DBWalletRecord(
        id: walletID,
        profileID: WalletDatabase.defaultProfileID,
        name: "Local Wallet",
        kind: DatabaseWalletKind.created.rawValue,
        secretKeyReference: secretReference,
        isSelected: true,
        sortOrder: 0,
        createdAt: 2_000_000_000,
        updatedAt: 2_000_000_000,
        lastOpenedAt: 2_000_000_000,
        archivedAt: nil
      )
      wallet.iCloudBackupUpdatedAt = 2_000_000_100
      wallet.iCloudBackupVerificationVersion = 1
      wallet.iCloudBackupRecordChangeTag = "verified-tag"
      wallet.iCloudBackupWalletID = cloudWalletID
      try wallet.insert(database)
    }

    try await database.clearICloudBackupRemoteVerification(
      walletID: cloudWalletID
    )

    let stored = try await database.pool.read { database in
      let record = try DBWalletRecord.fetchOne(database, key: walletID)
      return try #require(record)
    }
    #expect(stored.secretKeyReference == secretReference)
    #expect(stored.iCloudBackupUpdatedAt == nil)
    #expect(stored.iCloudBackupVerificationVersion == 0)
    #expect(stored.iCloudBackupRecordChangeTag == nil)
    #expect(stored.iCloudBackupWalletID == nil)
  }

  @Test
  func remoteVerificationPersistsTheRealCloudWalletIdentity()
    async throws
  {
    let database = try WalletDatabase.temporary()
    let localWalletID = "restored-local-wallet"
    let cloudWalletID = "original-cloud-wallet"
    try await database.pool.write { database in
      let wallet = DBWalletRecord(
        id: localWalletID,
        profileID: WalletDatabase.defaultProfileID,
        name: "Restored Wallet",
        kind: DatabaseWalletKind.created.rawValue,
        secretKeyReference: "local-secret-reference",
        isSelected: true,
        sortOrder: 0,
        createdAt: 2_000_000_000,
        updatedAt: 2_000_000_000,
        lastOpenedAt: 2_000_000_000,
        archivedAt: nil
      )
      try wallet.insert(database)
    }
    let receipt = WalletCloudBackupReceipt(
      serverModifiedAt: Date(timeIntervalSince1970: 2_000_000_100),
      serverChangeTag: "cloud-content-digest"
    )

    try await database.markICloudBackupRemoteVerified(
      walletID: localWalletID,
      cloudWalletID: cloudWalletID,
      receipt: receipt
    )

    let stored = try await database.pool.read { database in
      try #require(
        try DBWalletRecord.fetchOne(database, key: localWalletID)
      )
    }
    #expect(stored.iCloudBackupWalletID == cloudWalletID)
    #expect(stored.iCloudBackupVerificationVersion == 1)
    #expect(stored.iCloudBackupRecordChangeTag == "cloud-content-digest")
    #expect(stored.iCloudBackupUpdatedAt == 2_000_000_100)
  }

  @Test
  func clearingStatusForBackupWithoutLocalWalletIsIdempotent()
    async throws
  {
    let database = try WalletDatabase.temporary()

    try await database.clearICloudBackupRemoteVerification(
      walletID: "remote-only-wallet"
    )
    try await database.clearICloudBackupRemoteVerification(
      walletID: "remote-only-wallet"
    )
  }

  @Test
  func everyStandardExportedKeyProducesAValidatedRestorePayload()
    throws
  {
    let credential = try WalletRecoveryCredential(
      mnemonic:
        "abandon abandon abandon abandon abandon abandon "
        + "abandon abandon abandon abandon abandon about",
      passphrase: ""
    )
    let sourceDraft = try WalletCoreService.importRecoveryPhrase(
      credential.mnemonic
    )
    let sourceWallet = ManagedWallet(
      id: "private-key-export-source",
      name: "Source Wallet",
      kind: .created,
      address: sourceDraft.address,
      fiatUSDBalance: 0,
      isSelected: true,
      notificationsEnabledWhenInactive: false,
      backupState: .notVerified,
      backupVerifiedAt: nil,
      iCloudBackupUpdatedAt: nil,
      mnemonicWordCount: credential.wordCount,
      createdAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
    let items = try WalletDatabase
      .recoveryPhrasePrivateKeyExportItems(credential: credential)

    #expect(!items.isEmpty)
    for item in items {
      for privateKey in item.privateKeys {
        let configuration = try
          WalletPrivateKeyCloudBackupConfiguration(
            sourceWallet: sourceWallet,
            itemTitle: item.localizedTitle,
            encodedPrivateKey: privateKey.value,
            network: item.backupNetwork
          )
        let payload = WalletCloudBackupPayload(
          version: 3,
          walletName: configuration.walletName,
          walletKind: ManagedWalletKind.importedPrivateKey.rawValue,
          address: configuration.metadata.address,
          secret: Data(configuration.privateKeyData.hexString.utf8),
          hasPassphrase: nil,
          privateKeyNetwork:
            configuration.metadata.network.rawValue,
          privateKeyFormat:
            configuration.metadata.format.rawValue,
          createdAt: sourceWallet.createdAt.timeIntervalSince1970,
          backedUpAt: 2_000_000_100
        )
        let restored = try ICloudWalletRestoreValidator.validate(
          payload
        )

        guard case let .privateKey(data, network, format) =
          restored.draft.secret
        else {
          Issue.record("Expected a restorable private-key draft")
          continue
        }
        #expect(data == configuration.privateKeyData)
        #expect(network == configuration.metadata.network)
        #expect(format == configuration.metadata.format)
        #expect(restored.draft.address == configuration.metadata.address)
        #expect(
          configuration.cloudWalletID.hasPrefix(
            WalletPrivateKeyCloudBackupConfiguration.identityPrefix
          )
        )
        #expect(configuration.walletName.count <= 64)
      }
    }
  }

  @Test
  @MainActor
  func oneKeyBackupEncryptsRestoresAndDeletesWithoutTouchingWalletBackup()
    async throws
  {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let passkeyAuthorizer = ICloudBackupPasskeyAuthorizerProbe()
    let dataKeyStore = ICloudBackupDataKeyStoreProbe()
    let service = WalletAutomaticCloudBackupService(
      passkeyAuthorizer: passkeyAuthorizer,
      dataKeyStore: dataKeyStore,
      documentStore: WalletICloudDriveBackupStore(
        containerURLProvider: { root }
      )
    )
    let credential = try WalletRecoveryCredential(
      mnemonic:
        "abandon abandon abandon abandon abandon abandon "
        + "abandon abandon abandon abandon abandon about",
      passphrase: ""
    )
    let sourceDraft = try WalletCoreService.importRecoveryPhrase(
      credential.mnemonic
    )
    let sourceWallet = ManagedWallet(
      id: "full-wallet-\(UUID().uuidString)",
      name: "Main Wallet",
      kind: .created,
      address: sourceDraft.address,
      fiatUSDBalance: 0,
      isSelected: true,
      notificationsEnabledWhenInactive: false,
      backupState: .notVerified,
      backupVerifiedAt: nil,
      iCloudBackupUpdatedAt: nil,
      mnemonicWordCount: credential.wordCount,
      createdAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
    _ = try await service.backup(
      wallet: sourceWallet,
      material: .recoveryPhrase(credential),
      privateKeyMetadata: nil
    )

    let item = try #require(
      WalletDatabase.recoveryPhrasePrivateKeyExportItems(
        credential: credential
      ).first { $0.backupNetwork == .solana }
    )
    let privateKey = try #require(item.privateKeys.first)
    let configuration = try
      WalletPrivateKeyCloudBackupConfiguration(
        sourceWallet: sourceWallet,
        itemTitle: item.localizedTitle,
        encodedPrivateKey: privateKey.value,
        network: item.backupNetwork
      )
    let sameKeyFromAnotherPresentation = try
      WalletPrivateKeyCloudBackupConfiguration(
        sourceWallet: sourceWallet,
        itemTitle: "Alternate Presentation",
        encodedPrivateKey: privateKey.value,
        network: item.backupNetwork
      )
    #expect(configuration.cloudWalletID != sourceWallet.id)
    #expect(
      sameKeyFromAnotherPresentation.cloudWalletID
        == configuration.cloudWalletID
    )

    let receipt = try await configuration.createBackup(using: service)
    #expect(!receipt.serverChangeTag.isEmpty)
    let descriptors = try await service.availableBackups()
    #expect(Set(descriptors.map(\.walletID)) == [
      sourceWallet.id,
      configuration.cloudWalletID,
    ])

    let exactDescriptor = try await configuration.descriptor(
      using: service
    )
    #expect(exactDescriptor.walletID == configuration.cloudWalletID)
    #expect(exactDescriptor.walletName == configuration.walletName)

    let restoreResult = try await service.restoreResult(
      walletID: configuration.cloudWalletID
    )
    let restored = try ICloudWalletRestoreValidator.validate(
      restoreResult.payload
    )
    guard case let .privateKey(data, network, format) =
      restored.draft.secret
    else {
      Issue.record("Expected the encrypted backup to restore one key")
      return
    }
    #expect(data == configuration.privateKeyData)
    #expect(network == configuration.metadata.network)
    #expect(format == configuration.metadata.format)
    #expect(restored.draft.address == configuration.metadata.address)

    let restoredWallet = ManagedWallet(
      id: "new-local-wallet-id",
      name: restored.walletName,
      kind: .importedPrivateKey,
      address: restored.draft.address,
      fiatUSDBalance: 0,
      isSelected: true,
      notificationsEnabledWhenInactive: false,
      backupState: .notVerified,
      backupVerifiedAt: nil,
      iCloudBackupUpdatedAt: receipt.serverModifiedAt,
      iCloudBackupWalletID: restoreResult.remoteIdentity.walletID,
      mnemonicWordCount: nil,
      createdAt: sourceWallet.createdAt
    )
    let relinkedConfiguration = try
      WalletPrivateKeyCloudBackupConfiguration(
        sourceWallet: restoredWallet,
        itemTitle: item.localizedTitle,
        encodedPrivateKey: privateKey.value,
        network: item.backupNetwork
      )
    #expect(
      relinkedConfiguration.cloudWalletID
        == configuration.cloudWalletID
    )

    try await configuration.removeBackup(using: service)
    #expect(
      try await service.backupDescriptor(
        walletID: sourceWallet.id
      ).walletID == sourceWallet.id
    )
    await #expect(throws: WalletCloudBackupError.backupNotFound) {
      _ = try await service.backupDescriptor(
        walletID: configuration.cloudWalletID
      )
    }
    let fullRestore = try await service.restore(
      walletID: sourceWallet.id
    )
    #expect(
      try WalletRecoveryCredential.decode(fullRestore.secret)
        == credential
    )
  }
}

@MainActor
private final class ICloudBackupCancelingPasskeyAuthorizerProbe:
  WalletBackupPasskeyAuthorizing,
  @unchecked Sendable
{
  func register(
    walletID _: String,
    walletName _: String,
    prfSalt _: Data,
    presentationAnchor _: WalletPasskeyPresentationAnchor?
  ) throws -> WalletBackupPasskeyRegistration {
    throw WalletCloudBackupError.passkeyCanceled
  }

  func deriveWrappingKey(
    walletID _: String,
    credentialID _: Data,
    prfSalt _: Data,
    presentationAnchor _: WalletPasskeyPresentationAnchor?
  ) throws -> SymmetricKey {
    throw WalletCloudBackupError.passkeyCanceled
  }
}

@MainActor
private final class ICloudBackupMaterialRequestProbe {
  private(set) var requestCount = 0

  func material(
    authorization: WalletPasskeyBackupAuthorization,
    walletID: String
  ) -> WalletSensitiveMaterial {
    requestCount += 1
    #expect(authorization.permits(walletID: walletID))
    return .privateKey(String(repeating: "0", count: 64))
  }
}

@MainActor
final class ICloudBackupPasskeyAuthorizerProbe:
  WalletBackupPasskeyAuthorizing,
  @unchecked Sendable
{
  private struct Record {
    let credentialID: Data
    let prfSalt: Data
    let keyData: Data
  }

  private var records: [String: Record] = [:]
  private var registrations: [String] = []
  private var assertions: [String] = []

  func register(
    walletID: String,
    walletName _: String,
    prfSalt: Data,
    presentationAnchor _: WalletPasskeyPresentationAnchor?
  ) throws -> WalletBackupPasskeyRegistration {
    let userHandle = WalletBackupPasskeyIdentity.userHandle(
      walletID: walletID
    )
    let credentialID = Data(
      SHA256.hash(data: userHandle + prfSalt)
    )
    let keyData = Data(
      SHA256.hash(
        data: Data("test-passkey-prf".utf8)
          + userHandle
          + prfSalt
      )
    )
    records[walletID] = Record(
      credentialID: credentialID,
      prfSalt: prfSalt,
      keyData: keyData
    )
    registrations.append(walletID)
    return WalletBackupPasskeyRegistration(
      credentialID: credentialID,
      wrappingKey: SymmetricKey(data: keyData)
    )
  }

  func deriveWrappingKey(
    walletID: String,
    credentialID: Data,
    prfSalt: Data,
    presentationAnchor _: WalletPasskeyPresentationAnchor?
  ) throws -> SymmetricKey {
    guard let record = records[walletID],
      record.credentialID == credentialID,
      record.prfSalt == prfSalt
    else {
      throw WalletCloudBackupError.passkeyCredentialMismatch
    }
    assertions.append(walletID)
    return SymmetricKey(data: record.keyData)
  }

  func registeredWalletIDs() -> [String] {
    registrations
  }

  func assertedWalletIDs() -> [String] {
    assertions
  }
}

actor ICloudBackupDataKeyStoreProbe:
  WalletBackupDataKeyStoring
{
  private struct Record {
    let credentialID: Data
    let keyData: Data
  }

  private var records: [String: Record] = [:]

  func dataKey(
    walletID: String,
    credentialID: Data
  ) -> SymmetricKey? {
    guard let record = records[walletID],
      record.credentialID == credentialID
    else {
      return nil
    }
    return SymmetricKey(data: record.keyData)
  }

  func storeDataKey(
    _ key: SymmetricKey,
    walletID: String,
    credentialID: Data
  ) {
    records[walletID] = Record(
      credentialID: credentialID,
      keyData: key.withUnsafeBytes { Data($0) }
    )
  }

  func deleteDataKey(walletID: String) {
    records.removeValue(forKey: walletID)
  }

  func removeAllDataKeys() {
    records.removeAll()
  }

  func contains(walletID: String) -> Bool {
    records[walletID] != nil
  }
}

private actor ICloudBackupDeletionRecorder {
  enum LocalFailure: Error {
    case forced
  }

  private let storageFailureWalletID: String?
  private let localFailureWalletID: String?
  private var remoteCalls: [String] = []
  private var localCalls: [String] = []

  init(
    storageFailureWalletID: String? = nil,
    localFailureWalletID: String? = nil
  ) {
    self.storageFailureWalletID = storageFailureWalletID
    self.localFailureWalletID = localFailureWalletID
  }

  func deleteRemote(_ walletID: String) throws {
    remoteCalls.append(walletID)
    if walletID == storageFailureWalletID {
      throw WalletCloudBackupError.storageFailed
    }
  }

  func clearLocal(_ walletID: String) throws {
    localCalls.append(walletID)
    if walletID == localFailureWalletID {
      throw LocalFailure.forced
    }
  }

  func calls() -> (remote: [String], local: [String]) {
    (remoteCalls, localCalls)
  }
}
