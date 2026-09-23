import Foundation
import Testing

@testable import Aperture

@Suite(.serialized)
struct WalletPasskeyCloudBackupDiscoveryTests {
  @MainActor
  @Test
  func discoveryRetriesAnInitiallyEmptyICloudDriveRead() async {
    let probe = PasskeyBackupDiscoveryProbe(
      results: [
        .success([]),
        .success([
          WalletCloudBackupDescriptor(
            walletID: "passkey-wallet",
            walletName: "Passkey Wallet"
          )
        ]),
      ]
    )
    let model = probe.makeModel(delays: [.zero, .zero])

    model.start()
    defer { model.stop() }

    await probe.waitUntil {
      model.backupWalletIDs == ["passkey-wallet"]
        && !model.isLoading
    }

    #expect(probe.loadCount == 2)
    #expect(model.loadFailure == nil)
  }

  @MainActor
  @Test
  func returningToForegroundReconcilesNewPasskeyBackups() async {
    let probe = PasskeyBackupDiscoveryProbe(
      results: [.success([])]
    )
    let model = probe.makeModel(delays: [.zero])

    model.start()
    defer { model.stop() }
    await probe.waitUntil {
      !model.isLoading && model.backupWalletIDs.isEmpty
    }

    probe.enqueue(
      .success([
        WalletCloudBackupDescriptor(
          walletID: "foreground-passkey-wallet",
          walletName: nil
        )
      ])
    )
    model.refreshAfterForeground()

    await probe.waitUntil {
      model.backupWalletIDs == ["foreground-passkey-wallet"]
        && !model.isLoading
    }
    #expect(probe.loadCount == 2)
  }

  @MainActor
  @Test
  func discoveryNormalizesAndSortsPasskeyDocuments() async {
    let alphaBackupDate = Date(timeIntervalSince1970: 1_700_000_000)
    let oldZebraBackupDate = Date(timeIntervalSince1970: 1_600_000_000)
    let zebraBackupDate = Date(timeIntervalSince1970: 1_800_000_000)
    let probe = PasskeyBackupDiscoveryProbe(
      results: [
        .success([
          WalletCloudBackupDescriptor(
            walletID: "wallet-z",
            walletName: nil,
            backedUpAt: oldZebraBackupDate,
            hasPassphrase: true
          ),
          WalletCloudBackupDescriptor(
            walletID: "wallet-a",
            walletName: "Alpha",
            backedUpAt: alphaBackupDate,
            hasPassphrase: true
          ),
          WalletCloudBackupDescriptor(
            walletID: "wallet-z",
            walletName: "Zebra",
            backedUpAt: zebraBackupDate
          ),
        ])
      ]
    )
    let model = probe.makeModel(delays: [.zero])

    model.start()
    defer { model.stop() }
    await probe.waitUntil { !model.isLoading }

    #expect(model.backupWalletIDs == ["wallet-z", "wallet-a"])
    #expect(model.backups.map(\.walletName) == ["Zebra", "Alpha"])
    #expect(
      model.backups.map(\.backedUpAt)
        == [zebraBackupDate, alphaBackupDate]
    )
    #expect(model.backups.map(\.hasPassphrase) == [true, true])
  }

  @MainActor
  @Test
  func bothRestoreFlowsKeepNewestFirstAcrossRefreshes() async throws {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let input = [
      WalletCloudBackupDescriptor(walletID: "unknown-z", walletName: "A"),
      WalletCloudBackupDescriptor(walletID: "old", walletName: "A", backedUpAt: date.addingTimeInterval(-60)),
      WalletCloudBackupDescriptor(walletID: "new-z", walletName: "A", backedUpAt: date),
      WalletCloudBackupDescriptor(walletID: "unknown-a", walletName: "Z"),
      WalletCloudBackupDescriptor(walletID: "new-a", walletName: "Z", backedUpAt: date),
    ]
    var loaded = input
    var reads = 0
    let loader: () async throws -> [WalletCloudBackupDescriptor] = {
      reads += 1
      return loaded
    }
    let restore = ICloudWalletRestoreDiscoveryModel(loadBackups: loader, reconciliationDelays: [.zero])
    let switcher = WalletSwitcherICloudDiscoveryModel(loadBackups: loader, reconciliationDelays: [.zero])
    restore.start()
    switcher.start()
    defer { restore.stop(); switcher.stop() }
    let expected = ["new-a", "new-z", "old", "unknown-a", "unknown-z"]
    for _ in 0..<500 where restore.isLoading || switcher.isLoading {
      try await Task.sleep(for: .milliseconds(2))
    }
    #expect(restore.backupWalletIDs == expected)
    #expect(switcher.backupWalletIDs == expected)
    loaded = input.reversed()
    restore.refreshAfterForeground()
    switcher.refreshAfterForeground()
    for _ in 0..<500 where reads < 4 {
      try await Task.sleep(for: .milliseconds(2))
    }
    #expect(reads == 4)
    #expect(restore.backupWalletIDs == expected)
    #expect(switcher.backupWalletIDs == expected)
  }

  @MainActor
  @Test
  func discoverySurfacesICloudDriveStorageFailure() async {
    let probe = PasskeyBackupDiscoveryProbe(
      results: [.failure(.storageFailed)]
    )
    let model = probe.makeModel(delays: [.zero])

    model.start()
    defer { model.stop() }
    await probe.waitUntil { model.loadFailure != nil }

    #expect(model.loadFailure == .storageUnavailable)
    #expect(
      model.loadErrorKey
        == "settings.wallets.backup.icloud.drive.error"
    )
  }
}

@Suite
struct WalletPasskeyFailurePresentationTests {
  @Test
  func authorizationFailurePreservesActionableSystemDetails() {
    let systemError = NSError(
      domain: "com.apple.AuthenticationServices.AuthorizationError",
      code: 1004,
      userInfo: [
        NSLocalizedDescriptionKey:
          "The request was not interactive.\nTry again.",
        NSLocalizedFailureReasonErrorKey:
          "The presentation context was temporarily inactive.",
        NSLocalizedRecoverySuggestionErrorKey:
          "Return to Aperture and retry.",
      ]
    )
    let failure = WalletCloudBackupFailure(
      category: .passkeyPresentationUnavailable,
      diagnostic: WalletCloudBackupDiagnostic(error: systemError)
    )
    let error: any Error = failure

    #expect(
      error.walletCloudBackupCategory
        == .passkeyPresentationUnavailable
    )
    #expect(
      error.walletCloudBackupDiagnostic?.reference
        == "com.apple.AuthenticationServices.AuthorizationError "
          + "(1004): The request was not interactive. Try again.: "
          + "The presentation context was temporarily inactive.: "
          + "Return to Aperture and retry."
    )
  }

  @Test
  func operationFailureProvidesSupportEmailWithDiagnostic() throws {
    let failure = WalletCloudBackupFailure(
      category: .passkeyAuthorizationFailed,
      diagnostic: WalletCloudBackupDiagnostic(
        domain: "com.apple.AuthenticationServices.AuthorizationError",
        code: 1000,
        description: "Authorization failed"
      )
    )
    let presentation = WalletOperationFailurePresentation(
      messageKey: "settings.wallets.backup.passkey.authorization.error",
      error: failure
    )
    let supportURL = try #require(presentation.supportURL)
    let components = try #require(
      URLComponents(url: supportURL, resolvingAgainstBaseURL: false)
    )

    #expect(components.scheme == "mailto")
    #expect(components.path == WalletSupport.emailAddress)
    #expect(
      components.queryItems?
        .first(where: { $0.name == "body" })?
        .value?
        .contains(
          "com.apple.AuthenticationServices.AuthorizationError (1000)"
        ) == true
    )
  }

  @MainActor
  @Test
  func missingPresentationAnchorReturnsConcreteDiagnostic() async {
    do {
      _ = try await WalletPasskeyPresentationCoordinator.activeAnchor(nil)
      Issue.record("Expected the missing anchor to fail")
    } catch {
      #expect(
        error.walletCloudBackupCategory
          == .passkeyPresentationUnavailable
      )
      #expect(
        error.walletCloudBackupDiagnostic?.reference.contains(
          "presentation_anchor_unavailable"
        ) == true
      )
    }
  }
}

@MainActor
private final class PasskeyBackupDiscoveryProbe {
  private var results:
    [Result<
      [WalletCloudBackupDescriptor],
      WalletCloudBackupError
    >]
  private(set) var loadCount = 0

  init(
    results: [Result<
      [WalletCloudBackupDescriptor],
      WalletCloudBackupError
    >]
  ) {
    self.results = results
  }

  func makeModel(
    delays: [Duration]
  ) -> ICloudWalletRestoreDiscoveryModel {
    ICloudWalletRestoreDiscoveryModel(
      loadBackups: { [weak self] in
        try self?.load() ?? []
      },
      sleep: { _ in },
      reconciliationDelays: delays
    )
  }

  func enqueue(
    _ result: Result<
      [WalletCloudBackupDescriptor],
      WalletCloudBackupError
    >
  ) {
    results.append(result)
  }

  func waitUntil(
    timeoutIterations: Int = 500,
    condition: () -> Bool
  ) async {
    for _ in 0..<timeoutIterations {
      if condition() {
        return
      }
      try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("Timed out waiting for passkey backup discovery")
  }

  private func load() throws -> [WalletCloudBackupDescriptor] {
    loadCount += 1
    guard !results.isEmpty else { return [] }
    return try results.removeFirst().get()
  }
}
