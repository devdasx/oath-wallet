import Foundation

/// Home owns the task lifetime. Network awaits and parsing run on this actor,
/// independently of import completion, account history, and the main actor.
actor TronPermissionMonitor {
    typealias Loader = @Sendable (String) async throws -> TronAccountPermissions
    private let loader: Loader
    private var checkingWalletIDs: Set<String> = []

    init(loader: @escaping Loader = { address in
        try await SendTronAPIClient().accountPermissions(address: address)
    }) {
        self.loader = loader
    }

    nonisolated static func isEligible(kind: String) -> Bool {
        kind == ManagedWalletKind.importedRecoveryPhrase.rawValue
            || kind == ManagedWalletKind.importedPrivateKey.rawValue
    }

    func check(database: WalletDatabase, displayedAddress: String, expectedWalletID: String? = nil) async -> TronPermissionCheckRecord? {
        var context: (walletID: String, address: String)?
        // Timestamp at request start ensures a slower older response cannot
        // overwrite a newer observation in the database.
        let startedAt = Date().timeIntervalSince1970
        do {
            guard let identity = try await database.selectedWalletIdentity(),
                  expectedWalletID == nil || expectedWalletID == identity.walletID,
                  AppRootWalletAddressMatcher.matches(identity.address, displayedAddress) else { return nil }
            let wallet = try await database.managedWallet(walletID: identity.walletID)
            guard Self.isEligible(kind: wallet.kind.rawValue),
                  try await database.walletCapabilities(walletID: identity.walletID)
                    .permits(networkID: TronConstants.networkID) else { return nil }
            if let cached = try await database.confirmedTronCheck(walletID: identity.walletID) {
                guard try await database.selectedWalletIdentity()?.walletID == identity.walletID else { return nil }
                return cached
            }
            guard checkingWalletIDs.insert(identity.walletID).inserted else { return nil }
            defer { checkingWalletIDs.remove(identity.walletID) }
            let material = try await database.ensureTronAccount(walletID: identity.walletID)
            context = (identity.walletID, material.address)
            try Task.checkCancellation()
            let assessment = try await loader(material.address)
            try Task.checkCancellation()
            guard assessment.address == material.address else {
                throw SendTransactionSubmissionError.provider(
                    networkID: TronConstants.networkID,
                    code: "invalid_account_permissions_address_mismatch",
                    message: WalletLocalization.string("tron.permissions.unavailable")
                )
            }
            let record = TronPermissionCheckRecord(
                walletID: identity.walletID, address: material.address, checkedAt: startedAt,
                // The stored state keeps its original name; it now also covers an
                // owner permission that another key holds.
                state: !assessment.isActivated ? "inactive"
                    : assessment.isRestricted ? "multisignature" : "single",
                permissionIDsJSON: String(decoding: try JSONEncoder().encode(
                    assessment.restrictedPermissionIDs), as: UTF8.self),
                failureCode: nil
            )
            guard try await database.storeTronPermissionCheck(record),
                  try await database.selectedWalletIdentity()?.walletID == identity.walletID else { return nil }
            try Task.checkCancellation()
            return record
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled, let context else { return nil }
            let code = (error as? SendTransactionSubmissionError)?.diagnosticCode
                ?? WalletSyncDiagnosticErrorDetail.value(for: error)
            let record = TronPermissionCheckRecord(
                walletID: context.walletID, address: context.address, checkedAt: startedAt,
                state: "unknown", permissionIDsJSON: "[]", failureCode: code
            )
            _ = try? await database.storeTronPermissionCheck(record)
            return nil
        }
    }
}
