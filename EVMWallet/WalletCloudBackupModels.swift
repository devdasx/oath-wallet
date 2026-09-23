import Foundation
import Security

enum WalletCloudBackupError: Error, Sendable, Equatable {
  case iCloudUnavailable
  case randomGenerationFailed(OSStatus)
  case backupKeyUnavailable
  case keychainFailure(OSStatus)
  case passkeyCanceled
  case passkeyConfigurationUnavailable
  case passkeyDeviceNotConfigured
  case passkeyAuthorizationFailed
  case passkeyPRFUnavailable
  case passkeyCredentialMismatch
  case passkeyPresentationUnavailable
  case invalidPasskeyCredential
  case encryptionFailed
  case backupNotFound
  case decryptionFailed
  case storageFailed
  case invalidBackupDocument
  case remoteVerificationFailed
}

extension WalletCloudBackupError {
  var diagnosticCode: String {
    switch self {
    case .iCloudUnavailable:
      "icloud_unavailable"
    case let .randomGenerationFailed(status):
      "secure_random_status_\(status)"
    case .backupKeyUnavailable:
      "backup_key_unavailable"
    case let .keychainFailure(status):
      "keychain_status_\(status)"
    case .passkeyCanceled:
      "passkey_canceled"
    case .passkeyConfigurationUnavailable:
      "passkey_configuration_unavailable"
    case .passkeyDeviceNotConfigured:
      "passkey_device_not_configured"
    case .passkeyAuthorizationFailed:
      "passkey_authorization_failed"
    case .passkeyPRFUnavailable:
      "passkey_prf_unavailable"
    case .passkeyCredentialMismatch:
      "passkey_credential_mismatch"
    case .passkeyPresentationUnavailable:
      "passkey_presentation_unavailable"
    case .invalidPasskeyCredential:
      "invalid_passkey_credential"
    case .encryptionFailed:
      "backup_encryption_failed"
    case .backupNotFound:
      "backup_not_found"
    case .decryptionFailed:
      "backup_decryption_failed"
    case .storageFailed:
      "icloud_drive_storage_failed"
    case .invalidBackupDocument:
      "invalid_backup_document"
    case .remoteVerificationFailed:
      "remote_backup_verification_failed"
    }
  }
}

struct WalletCloudBackupDiagnostic: Sendable, Equatable {
  let domain: String
  let code: Int
  let description: String
  let failureReason: String?
  let recoverySuggestion: String?

  init(error: any Error) {
    let error = error as NSError
    domain = Self.sanitized(error.domain, fallback: "unknown")
    code = error.code
    description = Self.sanitized(
      error.localizedDescription,
      fallback: "error_description_unavailable"
    )
    failureReason = Self.optionalSanitized(
      error.localizedFailureReason
    )
    recoverySuggestion = Self.optionalSanitized(
      error.localizedRecoverySuggestion
    )
  }

  init(
    domain: String,
    code: Int,
    description: String,
    failureReason: String? = nil,
    recoverySuggestion: String? = nil
  ) {
    self.domain = Self.sanitized(domain, fallback: "unknown")
    self.code = code
    self.description = Self.sanitized(
      description,
      fallback: "error_description_unavailable"
    )
    self.failureReason = Self.optionalSanitized(failureReason)
    self.recoverySuggestion = Self.optionalSanitized(
      recoverySuggestion
    )
  }

  var reference: String {
    var components = [
      "\(domain) (\(code))",
      description,
    ]
    if let failureReason,
      failureReason.caseInsensitiveCompare(description) != .orderedSame
    {
      components.append(failureReason)
    }
    if let recoverySuggestion,
      recoverySuggestion.caseInsensitiveCompare(description)
        != .orderedSame,
      failureReason?.caseInsensitiveCompare(recoverySuggestion)
        != .orderedSame
    {
      components.append(recoverySuggestion)
    }
    return components.joined(separator: ": ")
  }

  private static func optionalSanitized(_ value: String?) -> String? {
    guard let value else { return nil }
    let sanitized = sanitized(value, fallback: "")
    return sanitized.isEmpty ? nil : sanitized
  }

  private static func sanitized(
    _ value: String,
    fallback: String
  ) -> String {
    let collapsed = value
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    let safeScalars = collapsed.unicodeScalars.filter {
      $0.value >= 0x20 && $0.value != 0x7F
    }
    let result = String(String.UnicodeScalarView(safeScalars))
    let bounded = String(result.prefix(320))
    return bounded.isEmpty ? fallback : bounded
  }
}

struct WalletCloudBackupFailure: Error, Sendable, Equatable {
  let category: WalletCloudBackupError
  let diagnostic: WalletCloudBackupDiagnostic
}

extension Error {
  var walletCloudBackupCategory: WalletCloudBackupError? {
    if let category = self as? WalletCloudBackupError {
      return category
    }
    return (self as? WalletCloudBackupFailure)?.category
  }

  var walletCloudBackupDiagnostic: WalletCloudBackupDiagnostic? {
    (self as? WalletCloudBackupFailure)?.diagnostic
  }
}

struct WalletCloudBackupReceipt: Sendable, Equatable {
  let serverModifiedAt: Date
  let serverChangeTag: String
  let diagnosticOperationID: UUID?
  let diagnosticStartedAt: ContinuousClock.Instant?

  init(
    serverModifiedAt: Date,
    serverChangeTag: String,
    diagnosticOperationID: UUID? = nil,
    diagnosticStartedAt: ContinuousClock.Instant? = nil
  ) {
    self.serverModifiedAt = serverModifiedAt
    self.serverChangeTag = serverChangeTag
    self.diagnosticOperationID = diagnosticOperationID
    self.diagnosticStartedAt = diagnosticStartedAt
  }
}

struct WalletCloudBackupRemoteIdentity: Sendable, Equatable {
  let walletID: String
  let receipt: WalletCloudBackupReceipt
}

struct WalletCloudBackupRestoreResult: Sendable {
  let payload: WalletCloudBackupPayload
  let remoteIdentity: WalletCloudBackupRemoteIdentity
}

struct WalletCloudBackupDescriptor: Sendable, Equatable, Hashable,
  Identifiable
{
  let walletID: String
  let walletName: String?
  let backedUpAt: Date?
  let hasPassphrase: Bool?

  init(
    walletID: String,
    walletName: String?,
    backedUpAt: Date? = nil,
    hasPassphrase: Bool? = nil
  ) {
    self.walletID = walletID
    self.walletName = walletName
    self.backedUpAt = backedUpAt
    self.hasPassphrase = hasPassphrase
  }

  /// Newest backup first; missing dates follow dated backups. The ID keeps
  /// equal-date results stable across iCloud refreshes and dictionary iteration.
  static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
    switch (lhs.backedUpAt, rhs.backedUpAt) {
    case let (left?, right?) where left != right:
      return left > right
    case (.some, .none):
      return true
    case (.none, .some):
      return false
    default:
      return lhs.walletID < rhs.walletID
    }
  }

  var id: String { walletID }
}

struct WalletCloudBackupPayload: Codable, Sendable {
  let version: Int
  let walletName: String
  let walletKind: String
  let address: String
  let secret: Data
  let hasPassphrase: Bool?
  let privateKeyNetwork: String?
  let privateKeyFormat: String?
  let createdAt: Double
  let backedUpAt: Double
}
