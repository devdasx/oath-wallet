import CryptoKit
import Foundation
import GRDB
import Testing
@testable import Aperture

@MainActor
final class ICloudReplacementFixture {
    let root: URL
    let store: WalletICloudDriveBackupStore
    let authorizer = ICloudReplacementPasskeyAuthorizer()
    let keys = ICloudReplacementDataKeyStore()
    let wallet: ManagedWallet
    let credential: WalletRecoveryCredential

    var service: WalletAutomaticCloudBackupService {
        service(using: store)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root
        store = WalletICloudDriveBackupStore(containerURLProvider: { directory })
        credential = try WalletRecoveryCredential(
            mnemonic: Array(repeating: "abandon", count: 11).joined(separator: " ") + " about",
            passphrase: "replacement-test"
        )
        let draft = try WalletCoreService.importRecoveryPhrase(
            credential.mnemonic, passphrase: credential.passphrase
        )
        wallet = ManagedWallet(
            id: UUID().uuidString, name: "Replacement Test Wallet", kind: .created,
            address: draft.address, fiatUSDBalance: 0, isSelected: true,
            notificationsEnabledWhenInactive: false, backupState: .notVerified,
            backupVerifiedAt: nil, iCloudBackupUpdatedAt: nil, mnemonicWordCount: 12,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func service(using store: WalletICloudDriveBackupStore) -> WalletAutomaticCloudBackupService {
        WalletAutomaticCloudBackupService(
            passkeyAuthorizer: authorizer, dataKeyStore: keys, documentStore: store
        )
    }

    @discardableResult
    func create(
        using service: WalletAutomaticCloudBackupService? = nil,
        policy: WalletCloudBackupWritePolicy = .createOnly
    ) async throws -> WalletCloudBackupReceipt {
        try await (service ?? self.service).backup(
            wallet: wallet, privateKeyMetadata: nil, writePolicy: policy
        ) { [credential, wallet] authorization in
            #expect(authorization.permits(walletID: wallet.id))
            return .recoveryPhrase(credential)
        }
    }

    func privateKeyConfiguration() throws -> WalletPrivateKeyCloudBackupConfiguration {
        try WalletPrivateKeyCloudBackupConfiguration(
            sourceWallet: wallet, itemTitle: "Ethereum",
            encodedPrivateKey: String(repeating: "0", count: 63) + "1", network: .evm
        )
    }

    func database(
        localID: String? = nil,
        cloudID: String? = nil,
        secretReference: String = "test-opaque-reference"
    ) async throws -> WalletDatabase {
        let database = try WalletDatabase.temporary()
        let wallet = wallet
        try await database.pool.write { db in
            var record = DBWalletRecord(
                id: localID ?? wallet.id, profileID: WalletDatabase.defaultProfileID,
                name: wallet.name, kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: secretReference, isSelected: true, sortOrder: 0,
                createdAt: 1_700_000_000, updatedAt: 1_700_000_000,
                lastOpenedAt: 1_700_000_000, archivedAt: nil
            )
            record.iCloudBackupWalletID = cloudID
            try record.insert(db)
        }
        return database
    }

    func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Documents"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "aperturewallet" }
    }
}

@MainActor
final class ICloudReplacementPasskeyAuthorizer: WalletBackupPasskeyAuthorizing, @unchecked Sendable {
    var cancel = false
    private(set) var registrationRequests = 0
    private(set) var registrations = 0
    private(set) var assertions = 0

    func register(
        walletID: String, walletName: String, prfSalt: Data,
        presentationAnchor: WalletPasskeyPresentationAnchor?
    ) throws -> WalletBackupPasskeyRegistration {
        registrationRequests += 1
        if cancel { throw WalletCloudBackupError.passkeyCanceled }
        registrations += 1
        return WalletBackupPasskeyRegistration(
            credentialID: Data(SHA256.hash(data: Data(walletID.utf8) + prfSalt)),
            wrappingKey: key(walletID: walletID, salt: prfSalt)
        )
    }

    func deriveWrappingKey(
        walletID: String, credentialID: Data, prfSalt: Data,
        presentationAnchor: WalletPasskeyPresentationAnchor?
    ) throws -> SymmetricKey {
        if cancel { throw WalletCloudBackupError.passkeyCanceled }
        assertions += 1
        return key(walletID: walletID, salt: prfSalt)
    }

    private func key(walletID: String, salt: Data) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data(("test-only-" + walletID).utf8) + salt))
    }
}

actor ICloudReplacementDataKeyStore: WalletBackupDataKeyStoring {
    private var records: [String: (Data, Data)] = [:]
    func dataKey(walletID: String, credentialID: Data) -> SymmetricKey? {
        guard let record = records[walletID], record.0 == credentialID else { return nil }
        return SymmetricKey(data: record.1)
    }
    func storeDataKey(_ key: SymmetricKey, walletID: String, credentialID: Data) {
        records[walletID] = (credentialID, key.withUnsafeBytes { Data($0) })
    }
    func deleteDataKey(walletID: String) { records.removeValue(forKey: walletID) }
    func removeAllDataKeys() { records.removeAll() }
}
