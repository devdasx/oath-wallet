import Foundation
import Observation

@MainActor
@Observable
final class WalletSwitcherICloudDiscoveryModel {
  typealias Loader = () async throws
    -> [WalletCloudBackupDescriptor]
  typealias Sleeper = (Duration) async throws -> Void

  private(set) var backups: [WalletCloudBackupDescriptor] = []
  private(set) var isLoading = true
  private(set) var loadFailure: ICloudWalletRestoreLoadFailure?

  var backupWalletIDs: [String] {
    backups.map(\.walletID)
  }

  var loadErrorKey: String? {
    loadFailure?.localizationKey
  }

  @ObservationIgnored private let loadBackups: Loader
  @ObservationIgnored private let sleep: Sleeper
  @ObservationIgnored private let reconciliationDelays: [Duration]
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var refreshGeneration = 0
  @ObservationIgnored private var isStarted = false

  init(
    loadBackups: @escaping Loader = {
      try await WalletAutomaticCloudBackupService.shared
        .availableBackups()
    },
    sleep: @escaping Sleeper = { duration in
      try await Task.sleep(for: duration)
    },
    reconciliationDelays: [Duration] = [
      .zero,
      .milliseconds(400),
      .seconds(1),
      .seconds(2),
      .seconds(4),
      .seconds(8),
    ]
  ) {
    self.loadBackups = loadBackups
    self.sleep = sleep
    self.reconciliationDelays =
      reconciliationDelays.isEmpty
      ? [.zero]
      : reconciliationDelays
  }

  func start() {
    guard !isStarted else { return }
    isStarted = true
    scheduleReconciliation()
  }

  func stop() {
    guard isStarted else { return }
    refreshGeneration += 1
    refreshTask?.cancel()
    refreshTask = nil
    isStarted = false
  }

  func retry() {
    scheduleReconciliation()
  }

  func refreshAfterForeground() {
    guard isStarted else { return }
    scheduleReconciliation()
  }

  func remove(walletIDs: Set<String>) {
    guard !walletIDs.isEmpty else { return }
    backups.removeAll {
      walletIDs.contains($0.walletID)
    }
    loadFailure = nil
    isLoading = false
  }

  private func scheduleReconciliation() {
    refreshGeneration += 1
    let generation = refreshGeneration
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      await self?.reconcile(generation: generation)
    }
  }

  private func reconcile(generation: Int) async {
    if backups.isEmpty {
      isLoading = true
    }
    loadFailure = nil

    for delay in reconciliationDelays {
      guard isCurrent(generation) else { return }
      if delay != .zero {
        do {
          try await sleep(delay)
        } catch {
          return
        }
      }
      guard isCurrent(generation) else { return }

      do {
        let loadedBackups = try await loadBackups()
        guard isCurrent(generation) else { return }
        let normalizedBackups = normalize(loadedBackups)
        if !normalizedBackups.isEmpty {
          backups = normalizedBackups
          isLoading = false
          return
        }

        backups = []
        isLoading = false
      } catch is CancellationError {
        return
      } catch {
        guard isCurrent(generation) else { return }
        loadFailure = ICloudWalletRestoreLoadFailure(
          error: error
        )
        isLoading = false
        return
      }
    }
  }

  private func normalize(
    _ loadedBackups: [WalletCloudBackupDescriptor]
  ) -> [WalletCloudBackupDescriptor] {
    var byWalletID: [String: WalletCloudBackupDescriptor] = [:]
    for backup in loadedBackups where !backup.walletID.isEmpty {
      let normalizedName = backup.walletName.flatMap {
        WalletDefaultName.normalizedCustomName($0)
      }
      let normalized = WalletCloudBackupDescriptor(
        walletID: backup.walletID,
        walletName: normalizedName,
        backedUpAt: backup.backedUpAt,
        hasPassphrase: backup.hasPassphrase
      )
      if let existing = byWalletID[backup.walletID] {
        byWalletID[backup.walletID] = preferredDescriptor(
          normalized,
          over: existing
        )
      } else {
        byWalletID[backup.walletID] = normalized
      }
    }
    return byWalletID.values.sorted(by: WalletCloudBackupDescriptor.newestFirst)
  }

  private func preferredDescriptor(
    _ candidate: WalletCloudBackupDescriptor,
    over existing: WalletCloudBackupDescriptor
  ) -> WalletCloudBackupDescriptor {
    let prefersCandidate: Bool
    switch (candidate.backedUpAt, existing.backedUpAt) {
    case let (candidateDate?, existingDate?)
      where candidateDate != existingDate:
      prefersCandidate = candidateDate > existingDate
    case (.some, .none):
      prefersCandidate = true
    case (.none, .some):
      prefersCandidate = false
    default:
      prefersCandidate = candidate.walletName != nil
    }

    let preferred = prefersCandidate ? candidate : existing
    let fallback = prefersCandidate ? existing : candidate
    return WalletCloudBackupDescriptor(
      walletID: preferred.walletID,
      walletName: preferred.walletName ?? fallback.walletName,
      backedUpAt: preferred.backedUpAt,
      hasPassphrase:
        preferred.hasPassphrase ?? fallback.hasPassphrase
    )
  }

  private func isCurrent(_ generation: Int) -> Bool {
    !Task.isCancelled && generation == refreshGeneration
  }

}
