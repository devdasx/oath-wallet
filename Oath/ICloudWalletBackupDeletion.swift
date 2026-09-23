import Foundation

enum ICloudWalletBackupDeletionFailure: Equatable, Sendable {
  case accountUnavailable
  case invalidServerRecord
  case localMetadata
  case storageVerification
  case unexpected

  init(remoteError error: Error) {
    guard let backupError = error as? WalletCloudBackupError else {
      self = .unexpected
      return
    }

    switch backupError {
    case .iCloudUnavailable:
      self = .accountUnavailable
    case .storageFailed, .backupKeyUnavailable, .keychainFailure:
      self = .storageVerification
    case .invalidBackupDocument:
      self = .invalidServerRecord
    default:
      self = .unexpected
    }
  }

  var localizationKey: String {
    switch self {
    case .accountUnavailable:
      "import.icloud.delete.error.account"
    case .invalidServerRecord:
      "import.icloud.delete.error.invalid_record"
    case .localMetadata:
      "import.icloud.delete.error.local_metadata"
    case .storageVerification:
      "import.icloud.delete.error.storage_verification"
    case .unexpected:
      "import.icloud.delete.error.unexpected"
    }
  }

  var message: String {
    WalletLocalization.string(localizationKey)
  }
}

struct ICloudWalletBackupDeletionOutcome: Equatable, Sendable {
  let deletedWalletIDs: Set<String>
  let remainingWalletIDs: Set<String>
  let failure: ICloudWalletBackupDeletionFailure?
}

@MainActor
enum ICloudWalletBackupDeletionExecutor {
  static func execute(
    walletIDs: Set<String>,
    deleteRemoteBackup: (String) async throws -> Void,
    clearLocalVerification: (String) async throws -> Void
  ) async -> ICloudWalletBackupDeletionOutcome {
    let orderedWalletIDs = walletIDs.sorted()
    var deletedWalletIDs = Set<String>()

    for walletID in orderedWalletIDs {
      do {
        try await deleteRemoteBackup(walletID)
        deletedWalletIDs.insert(walletID)
      } catch {
        return ICloudWalletBackupDeletionOutcome(
          deletedWalletIDs: deletedWalletIDs,
          remainingWalletIDs:
            walletIDs.subtracting(deletedWalletIDs),
          failure: ICloudWalletBackupDeletionFailure(
            remoteError: error
          )
        )
      }

      do {
        try await clearLocalVerification(walletID)
      } catch {
        return ICloudWalletBackupDeletionOutcome(
          deletedWalletIDs: deletedWalletIDs,
          remainingWalletIDs:
            walletIDs.subtracting(deletedWalletIDs),
          failure: .localMetadata
        )
      }
    }

    return ICloudWalletBackupDeletionOutcome(
      deletedWalletIDs: deletedWalletIDs,
      remainingWalletIDs: [],
      failure: nil
    )
  }
}
