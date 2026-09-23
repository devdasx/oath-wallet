import CryptoKit
import Foundation

struct WalletPasskeyBackupAuthorization: Sendable {
  private let walletID: String
  private let expiresAt: Date

  fileprivate init(walletID: String) {
    self.walletID = walletID
    expiresAt = Date().addingTimeInterval(60)
  }

  func permits(walletID: String, now: Date = Date()) -> Bool {
    self.walletID == walletID && now <= expiresAt
  }
}

final class WalletAutomaticCloudBackupService: @unchecked Sendable {
  static let shared = WalletAutomaticCloudBackupService()

  private static let payloadVersion = 3
  private static let applicationName = "Aperture"

  private let passkeyAuthorizer: any WalletBackupPasskeyAuthorizing
  private let dataKeyStore: any WalletBackupDataKeyStoring
  private let documentStore: WalletICloudDriveBackupStore

  private struct ProtectionMaterial {
    let credentialID: Data
    let prfSalt: Data
    let wrappedDataKey: Data
    let dataKey: SymmetricKey
  }

  init(
    passkeyAuthorizer: any WalletBackupPasskeyAuthorizing =
      WalletBackupPasskeyAuthorizer.shared,
    dataKeyStore: any WalletBackupDataKeyStoring =
      WalletBackupDataKeyStore.shared,
    documentStore: WalletICloudDriveBackupStore = .shared
  ) {
    self.passkeyAuthorizer = passkeyAuthorizer
    self.dataKeyStore = dataKeyStore
    self.documentStore = documentStore
  }

  @MainActor
  func backup(
    wallet: ManagedWallet,
    material: WalletSensitiveMaterial,
    privateKeyMetadata: WalletImportedPrivateKeyMetadata?,
    presentationAnchor: WalletPasskeyPresentationAnchor? = nil,
    writePolicy: WalletCloudBackupWritePolicy = .replaceExisting
  ) async throws -> WalletCloudBackupReceipt {
    try validateBackupInput(
      wallet: wallet,
      material: material,
      privateKeyMetadata: privateKeyMetadata
    )
    let cloudWalletID = wallet.iCloudBackupWalletID ?? wallet.id
    let protection = try await protectionMaterial(
      for: wallet,
      cloudWalletID: cloudWalletID,
      requiresUserVerification: false,
      writePolicy: writePolicy,
      presentationAnchor: presentationAnchor
    )
    return try await persistBackup(
      wallet: wallet,
      material: material,
      privateKeyMetadata: privateKeyMetadata,
      cloudWalletID: cloudWalletID,
      protection: protection,
      writePolicy: writePolicy
    )
  }

  @MainActor
  func backup(
    wallet: ManagedWallet,
    privateKeyMetadata: WalletImportedPrivateKeyMetadata?,
    presentationAnchor: WalletPasskeyPresentationAnchor? = nil,
    writePolicy: WalletCloudBackupWritePolicy = .replaceExisting,
    materialProvider: @MainActor (
      WalletPasskeyBackupAuthorization
    ) async throws -> WalletSensitiveMaterial
  ) async throws -> WalletCloudBackupReceipt {
    let cloudWalletID = wallet.iCloudBackupWalletID ?? wallet.id
    let protection = try await protectionMaterial(
      for: wallet,
      cloudWalletID: cloudWalletID,
      requiresUserVerification: true,
      writePolicy: writePolicy,
      presentationAnchor: presentationAnchor
    )
    try Task.checkCancellation()
    let authorization = WalletPasskeyBackupAuthorization(
      walletID: wallet.id
    )
    let material = try await materialProvider(authorization)
    try Task.checkCancellation()
    return try await persistBackup(
      wallet: wallet,
      material: material,
      privateKeyMetadata: privateKeyMetadata,
      cloudWalletID: cloudWalletID,
      protection: protection,
      writePolicy: writePolicy
    )
  }

  @MainActor
  private func persistBackup(
    wallet: ManagedWallet,
    material: WalletSensitiveMaterial,
    privateKeyMetadata: WalletImportedPrivateKeyMetadata?,
    cloudWalletID: String,
    protection: ProtectionMaterial,
    writePolicy: WalletCloudBackupWritePolicy
  ) async throws -> WalletCloudBackupReceipt {
    try validateBackupInput(
      wallet: wallet,
      material: material,
      privateKeyMetadata: privateKeyMetadata
    )
    let encodedMaterial = try material.encodedData()
    let backupFormat: String? = {
      if case .bitcoinImportedWallet = material { return BitcoinImportedWalletMaterial.accountMarker }
      return privateKeyMetadata?.format.rawValue
    }()
    let now = Date()
    let payload = WalletCloudBackupPayload(
      version: Self.payloadVersion,
      walletName: wallet.name,
      walletKind: wallet.kind.rawValue,
      address: wallet.address,
      secret: encodedMaterial,
      hasPassphrase: material.hasPassphrase,
      privateKeyNetwork: { if case .bitcoinImportedWallet = material { return "bitcoin" }; return privateKeyMetadata?.network.rawValue }(),
      privateKeyFormat: backupFormat,
      createdAt: wallet.createdAt.timeIntervalSince1970,
      backedUpAt: now.timeIntervalSince1970
    )
    let encryptedPayload = try encryptPayload(
      payload,
      version: WalletICloudDriveBackupDocument.currentVersion,
      walletID: cloudWalletID,
      walletName: wallet.name,
      hasPassphrase: material.hasPassphrase,
      applicationName: Self.applicationName,
      credentialID: protection.credentialID,
      prfSalt: protection.prfSalt,
      wrappedDataKey: protection.wrappedDataKey,
      dataKey: protection.dataKey
    )
    let document = WalletICloudDriveBackupDocument(
      version: WalletICloudDriveBackupDocument.currentVersion,
      algorithm: WalletICloudDriveBackupDocument.algorithm,
      walletID: cloudWalletID,
      walletName: wallet.name,
      hasPassphrase: material.hasPassphrase,
      applicationName: Self.applicationName,
      passkeyCredentialID: protection.credentialID,
      passkeyPRFSalt: protection.prfSalt,
      wrappedDataKey: protection.wrappedDataKey,
      encryptedPayload: encryptedPayload,
      contentDigest: WalletICloudDriveBackupDocument.digest(
        walletID: cloudWalletID,
        walletName: wallet.name,
        hasPassphrase: material.hasPassphrase,
        applicationName: Self.applicationName,
        passkeyCredentialID: protection.credentialID,
        passkeyPRFSalt: protection.prfSalt,
        wrappedDataKey: protection.wrappedDataKey,
        encryptedPayload: encryptedPayload
      ),
      createdAt: wallet.createdAt.timeIntervalSince1970,
      modifiedAt: now.timeIntervalSince1970
    )

    // Validate the encrypted replacement before touching the current document.
    let candidatePayload = try decrypt(
      document,
      expectedWalletID: cloudWalletID,
      dataKey: protection.dataKey
    )
    guard payloadMatches(
      candidatePayload,
      matches: wallet,
      encodedMaterial: encodedMaterial,
      expectedPrivateKeyFormat: backupFormat,
      hasPassphrase: material.hasPassphrase,
      privateKeyMetadata: privateKeyMetadata
    ) else { throw WalletCloudBackupError.remoteVerificationFailed }
    try Task.checkCancellation()
    _ = try await documentStore.save(document, writePolicy: writePolicy)
    let fetched = try await documentStore.fetch(
      walletID: cloudWalletID
    )
    let verifiedPayload = try decrypt(
      fetched,
      expectedWalletID: cloudWalletID,
      dataKey: protection.dataKey
    )
    guard fetched == document,
      payloadMatches(
        verifiedPayload,
        matches: wallet,
        encodedMaterial: encodedMaterial,
        expectedPrivateKeyFormat: backupFormat,
        hasPassphrase: material.hasPassphrase,
        privateKeyMetadata: privateKeyMetadata
      )
    else {
      throw WalletCloudBackupError.remoteVerificationFailed
    }

    return WalletCloudBackupReceipt(
      serverModifiedAt: Date(
        timeIntervalSince1970: fetched.modifiedAt
      ),
      serverChangeTag: fetched.contentDigest.hexString
    )
  }

  @MainActor
  func restore(
    walletID: String,
    presentationAnchor: WalletPasskeyPresentationAnchor? = nil
  ) async throws -> WalletCloudBackupPayload {
    try await restoreResult(
      walletID: walletID,
      presentationAnchor: presentationAnchor
    ).payload
  }

  @MainActor
  func restoreResult(
    walletID: String,
    presentationAnchor: WalletPasskeyPresentationAnchor? = nil
  ) async throws -> WalletCloudBackupRestoreResult {
    let document = try await documentStore.fetch(walletID: walletID)
    guard document.walletID == walletID else {
      throw WalletCloudBackupError.invalidBackupDocument
    }
    // Explicit restore always reauthorizes the passkey. The local data-key
    // cache exists only so normal backup updates can remain silent.
    let wrappingKey =
      try await passkeyAuthorizer
      .deriveWrappingKey(
        walletID: walletID,
        credentialID: document.passkeyCredentialID,
        prfSalt: document.passkeyPRFSalt,
        presentationAnchor: presentationAnchor
      )
    let dataKey = try unwrapDataKey(
      document.wrappedDataKey,
      document: document,
      wrappingKey: wrappingKey
    )
    let payload = try decrypt(
      document,
      expectedWalletID: walletID,
      dataKey: dataKey
    )
    try await dataKeyStore.storeDataKey(
      dataKey,
      walletID: walletID,
      credentialID: document.passkeyCredentialID
    )
    return WalletCloudBackupRestoreResult(
      payload: payload,
      remoteIdentity: remoteIdentity(for: document)
    )
  }

  func availableBackups() async throws
    -> [WalletCloudBackupDescriptor]
  {
    try await documentStore.availableDocuments().map {
      backupDescriptor(for: $0)
    }
  }

  /// Reads one exact cloud identity. This deliberately does not perform the
  /// address-based repair used by `verifiedBackup(for:)`, because callers
  /// managing an independently backed-up private key must never match or
  /// remove the source wallet's full backup by accident.
  func backupDescriptor(
    walletID: String
  ) async throws -> WalletCloudBackupDescriptor {
    let document = try await documentStore.fetch(walletID: walletID)
    guard document.walletID == walletID else {
      throw WalletCloudBackupError.invalidBackupDocument
    }
    return backupDescriptor(for: document)
  }

  func verifiedBackup(
    for wallet: ManagedWallet
  ) async throws -> WalletCloudBackupRemoteIdentity {
    let linkedWalletID = wallet.iCloudBackupWalletID ?? wallet.id
    do {
      let document = try await documentStore.fetch(
        walletID: linkedWalletID
      )
      return remoteIdentity(for: document)
    } catch WalletCloudBackupError.backupNotFound {
      // A restore made by an affected app build received a fresh local ID.
      // Its successfully authorized data key remains cached under the real
      // iCloud document ID, which lets us repair the association without
      // another passkey prompt.
    }

    let documents = try await documentStore.availableDocuments()
      .sorted { $0.modifiedAt > $1.modifiedAt }
    for document in documents {
      guard let dataKey = try await dataKeyStore.dataKey(
        walletID: document.walletID,
        credentialID: document.passkeyCredentialID
      ),
        let payload = try? decrypt(
          document,
          expectedWalletID: document.walletID,
          dataKey: dataKey
        ),
        payloadBelongsToWallet(payload, wallet: wallet)
      else {
        continue
      }
      return remoteIdentity(for: document)
    }
    throw WalletCloudBackupError.backupNotFound
  }

  private func backupDate(from timestamp: Double) -> Date? {
    guard timestamp.isFinite, timestamp > 0 else { return nil }
    return Date(timeIntervalSince1970: timestamp)
  }

  private func backupDescriptor(
    for document: WalletICloudDriveBackupDocument
  ) -> WalletCloudBackupDescriptor {
    WalletCloudBackupDescriptor(
      walletID: document.walletID,
      walletName: WalletDefaultName.normalizedCustomName(
        document.walletName
      ),
      backedUpAt: backupDate(from: document.modifiedAt),
      hasPassphrase: document.hasPassphrase
    )
  }

  func removeBackup(
    walletID: String,
    expectsExistingBackup: Bool = false
  ) async throws {
    let removed = try await documentStore.remove(walletID: walletID)
    try await dataKeyStore.deleteDataKey(walletID: walletID)
    if expectsExistingBackup, !removed {
      throw WalletCloudBackupError.backupNotFound
    }
  }

  @discardableResult
  func removeAllBackups() async throws -> Int {
    let removedCount = try await documentStore.removeAll()
    try await dataKeyStore.removeAllDataKeys()
    return removedCount
  }

  @MainActor
  private func protectionMaterial(
    for wallet: ManagedWallet,
    cloudWalletID: String,
    requiresUserVerification: Bool,
    writePolicy: WalletCloudBackupWritePolicy,
    presentationAnchor: WalletPasskeyPresentationAnchor?
  ) async throws -> ProtectionMaterial {
    let existing: WalletICloudDriveBackupDocument?
    do {
      existing = try await documentStore.fetch(
        walletID: cloudWalletID
      )
    } catch WalletCloudBackupError.backupNotFound {
      existing = nil
    }

    try writePolicy.validate(existingBackup: existing != nil)
    if let existing {
      let dataKey: SymmetricKey
      if !requiresUserVerification,
        let cached = try await dataKeyStore.dataKey(
        walletID: cloudWalletID,
        credentialID: existing.passkeyCredentialID
      ) {
        dataKey = cached
      } else {
        let wrappingKey =
          try await passkeyAuthorizer
          .deriveWrappingKey(
            walletID: cloudWalletID,
            credentialID: existing.passkeyCredentialID,
            prfSalt: existing.passkeyPRFSalt,
            presentationAnchor: presentationAnchor
          )
        dataKey = try unwrapDataKey(
          existing.wrappedDataKey,
          document: existing,
          wrappingKey: wrappingKey
        )
        try await dataKeyStore.storeDataKey(
          dataKey,
          walletID: cloudWalletID,
          credentialID: existing.passkeyCredentialID
        )
      }
      return ProtectionMaterial(
        credentialID: existing.passkeyCredentialID,
        prfSalt: existing.passkeyPRFSalt,
        wrappedDataKey: existing.wrappedDataKey,
        dataKey: dataKey
      )
    }

    let prfSalt = try WalletBackupPasskeyIdentity.secureRandomData(
      count: WalletBackupPasskeyIdentity.prfSaltByteCount
    )
    let registration = try await passkeyAuthorizer.register(
      walletID: cloudWalletID,
      walletName: wallet.name,
      prfSalt: prfSalt,
      presentationAnchor: presentationAnchor
    )
    let dataKey = SymmetricKey(size: .bits256)
    let wrappedDataKey = try wrapDataKey(
      dataKey,
      version: WalletICloudDriveBackupDocument.currentVersion,
      walletID: cloudWalletID,
      applicationName: Self.applicationName,
      credentialID: registration.credentialID,
      prfSalt: prfSalt,
      wrappingKey: registration.wrappingKey
    )
    try await dataKeyStore.storeDataKey(
      dataKey,
      walletID: cloudWalletID,
      credentialID: registration.credentialID
    )
    return ProtectionMaterial(
      credentialID: registration.credentialID,
      prfSalt: prfSalt,
      wrappedDataKey: wrappedDataKey,
      dataKey: dataKey
    )
  }

  private func wrapDataKey(
    _ dataKey: SymmetricKey,
    version: Int,
    walletID: String,
    applicationName: String,
    credentialID: Data,
    prfSalt: Data,
    wrappingKey: SymmetricKey
  ) throws -> Data {
    let keyData = dataKey.withUnsafeBytes { Data($0) }
    guard keyData.count == 32 else {
      throw WalletCloudBackupError.encryptionFailed
    }
    return try seal(
      keyData,
      using: wrappingKey,
      authenticating:
        WalletICloudDriveBackupDocument
        .authenticatedContext(
          purpose: "data-key",
          version: version,
          walletID: walletID,
          walletName: "",
          applicationName: applicationName,
          passkeyCredentialID: credentialID,
          passkeyPRFSalt: prfSalt
        )
    )
  }

  private func unwrapDataKey(
    _ wrappedDataKey: Data,
    document: WalletICloudDriveBackupDocument,
    wrappingKey: SymmetricKey
  ) throws -> SymmetricKey {
    let keyData = try open(
      wrappedDataKey,
      using: wrappingKey,
      authenticating:
        WalletICloudDriveBackupDocument
        .authenticatedContext(
          purpose: "data-key",
          version: document.version,
          walletID: document.walletID,
          walletName: "",
          applicationName: document.applicationName,
          passkeyCredentialID: document.passkeyCredentialID,
          passkeyPRFSalt: document.passkeyPRFSalt
        )
    )
    guard keyData.count == 32 else {
      throw WalletCloudBackupError.decryptionFailed
    }
    return SymmetricKey(data: keyData)
  }

  private func encryptPayload(
    _ payload: WalletCloudBackupPayload,
    version: Int,
    walletID: String,
    walletName: String,
    hasPassphrase: Bool?,
    applicationName: String,
    credentialID: Data,
    prfSalt: Data,
    wrappedDataKey: Data,
    dataKey: SymmetricKey
  ) throws -> Data {
    let encoded: Data
    do {
      encoded = try JSONEncoder().encode(payload)
    } catch {
      throw WalletCloudBackupError.encryptionFailed
    }
    return try seal(
      encoded,
      using: dataKey,
      authenticating:
        WalletICloudDriveBackupDocument
        .authenticatedContext(
          purpose: "wallet-payload",
          version: version,
          walletID: walletID,
          walletName: walletName,
          hasPassphrase: hasPassphrase,
          applicationName: applicationName,
          passkeyCredentialID: credentialID,
          passkeyPRFSalt: prfSalt,
          binding: Data(SHA256.hash(data: wrappedDataKey))
        )
    )
  }

  private func decrypt(
    _ document: WalletICloudDriveBackupDocument,
    expectedWalletID: String,
    dataKey: SymmetricKey
  ) throws -> WalletCloudBackupPayload {
    guard document.walletID == expectedWalletID,
      document.applicationName == Self.applicationName,
      document.algorithm
        == WalletICloudDriveBackupDocument.algorithm,
      WalletICloudDriveBackupDocument.digest(
        version: document.version,
        walletID: document.walletID,
        walletName: document.walletName,
        hasPassphrase: document.hasPassphrase,
        applicationName: document.applicationName,
        passkeyCredentialID: document.passkeyCredentialID,
        passkeyPRFSalt: document.passkeyPRFSalt,
        wrappedDataKey: document.wrappedDataKey,
        encryptedPayload: document.encryptedPayload
      )
        == document.contentDigest,
      let payloadData = try? open(
        document.encryptedPayload,
        using: dataKey,
        authenticating:
          WalletICloudDriveBackupDocument
          .authenticatedContext(
            purpose: "wallet-payload",
            version: document.version,
            walletID: document.walletID,
            walletName: document.walletName,
            hasPassphrase: document.hasPassphrase,
            applicationName: document.applicationName,
            passkeyCredentialID:
              document.passkeyCredentialID,
            passkeyPRFSalt: document.passkeyPRFSalt,
            binding: Data(
              SHA256.hash(data: document.wrappedDataKey)
            )
          )
      ),
      let payload = try? JSONDecoder().decode(
        WalletCloudBackupPayload.self,
        from: payloadData
      ),
      payload.version == Self.payloadVersion,
      payload.hasPassphrase == document.hasPassphrase,
      WalletDefaultName.normalizedCustomName(
        payload.walletName
      ) != nil,
      ManagedWalletKind(rawValue: payload.walletKind) != nil,
      !payload.address.isEmpty,
      !payload.secret.isEmpty
    else {
      throw WalletCloudBackupError.decryptionFailed
    }
    return payload
  }

  private func seal(
    _ plaintext: Data,
    using key: SymmetricKey,
    authenticating authenticatedData: Data
  ) throws -> Data {
    do {
      let box = try AES.GCM.seal(
        plaintext,
        using: key,
        authenticating: authenticatedData
      )
      guard let combined = box.combined else {
        throw WalletCloudBackupError.encryptionFailed
      }
      return combined
    } catch let error as WalletCloudBackupError {
      throw error
    } catch {
      throw WalletCloudBackupError.encryptionFailed
    }
  }

  private func open(
    _ ciphertext: Data,
    using key: SymmetricKey,
    authenticating authenticatedData: Data
  ) throws -> Data {
    do {
      return try AES.GCM.open(
        AES.GCM.SealedBox(combined: ciphertext),
        using: key,
        authenticating: authenticatedData
      )
    } catch {
      throw WalletCloudBackupError.decryptionFailed
    }
  }

  private func validateBackupInput(
    wallet: ManagedWallet,
    material: WalletSensitiveMaterial,
    privateKeyMetadata: WalletImportedPrivateKeyMetadata?
  ) throws {
    if case let .bitcoinImportedWallet(imported) = material {
      guard wallet.kind == .importedPrivateKey, try imported.primaryAddress().address == wallet.address else {
        throw WalletCloudBackupError.encryptionFailed
      }
      _ = try imported.validated()
      return
    }
    guard
      wallet.kind != .importedPrivateKey
        || privateKeyMetadata != nil
    else {
      throw WalletCloudBackupError.encryptionFailed
    }
    guard wallet.kind == .importedPrivateKey else { return }
    guard
      let privateKeyMetadata,
      case .privateKey(let hexadecimal) = material,
      let privateKeyData = Data(hexString: hexadecimal),
      privateKeyData.count == 32,
      let draft = try? PrivateKeyImportService.revalidate(
        privateKeyData: privateKeyData,
        network: privateKeyMetadata.network,
        format: privateKeyMetadata.format
      ),
      privateKeyMetadata.matches(address: draft.address),
      privateKeyMetadata.matches(address: wallet.address)
    else {
      throw WalletCloudBackupError.encryptionFailed
    }
  }

  private func payloadMatches(
    _ payload: WalletCloudBackupPayload,
    matches wallet: ManagedWallet,
    encodedMaterial: Data,
    expectedPrivateKeyFormat: String?,
    hasPassphrase: Bool?,
    privateKeyMetadata: WalletImportedPrivateKeyMetadata?
  ) -> Bool {
    payload.address == wallet.address
      && payload.walletName == wallet.name
      && payload.walletKind == wallet.kind.rawValue
      && payload.secret == encodedMaterial
      && payload.hasPassphrase == hasPassphrase
      && payload.privateKeyNetwork
        == privateKeyMetadata?.network.rawValue
      && payload.privateKeyFormat == expectedPrivateKeyFormat
  }

  private func remoteIdentity(
    for document: WalletICloudDriveBackupDocument
  ) -> WalletCloudBackupRemoteIdentity {
    WalletCloudBackupRemoteIdentity(
      walletID: document.walletID,
      receipt: WalletCloudBackupReceipt(
        serverModifiedAt: Date(
          timeIntervalSince1970: document.modifiedAt
        ),
        serverChangeTag: document.contentDigest.hexString
      )
    )
  }

  private func payloadBelongsToWallet(
    _ payload: WalletCloudBackupPayload,
    wallet: ManagedWallet
  ) -> Bool {
    guard let payloadKind = ManagedWalletKind(
      rawValue: payload.walletKind
    ) else {
      return false
    }
    let compatibleKind: Bool
    if wallet.kind.hasRecoveryPhrase {
      compatibleKind = payloadKind.hasRecoveryPhrase
    } else {
      compatibleKind = wallet.kind == payloadKind
    }
    guard compatibleKind else { return false }

    if payload.address.hasPrefix("0x"),
      wallet.address.hasPrefix("0x")
    {
      return payload.address.caseInsensitiveCompare(wallet.address)
        == .orderedSame
    }
    return payload.address == wallet.address
  }
}
