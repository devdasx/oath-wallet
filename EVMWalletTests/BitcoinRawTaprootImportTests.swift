import Foundation
import GRDB
import P256K
import Testing
import WalletCore
@testable import Aperture

struct BitcoinRawTaprootImportTests {
    private static let vectorAddress =
        "sp1qqgste7k9hx0qftg6qmwlkqtwuy6cycyavzmzj85c6qdfhjdpdjtdgqjuex"
        + "zk6murw56suy3e0rd2cgqvycxttddwsvgxe2usfpxumr70xc9pkqwv"
    private static let mnemonic =
        "abandon abandon abandon abandon abandon abandon "
        + "abandon abandon abandon abandon abandon about"
    private static func data(_ hex: String) throws -> Data {
        try #require(Data(hexString: hex))
    }

    @Test
    func outputExportPreservesKeychainOwnershipAndExcludesSpentOutputs()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(
            service: "bitcoin-silent-payment-tests.\(UUID().uuidString)"
        )
        defer { try? vault.deleteAll() }
        let draft = try WalletCoreService.restoreEVMWallet(
            mnemonic: Self.mnemonic
        )
        let identity = try await database.persistCreatedWallet(
            draft: draft,
            security: .reuseExistingProfile,
            vault: vault
        )
        let accountBeforeInitialization = try await database
            .bitcoinSilentPaymentAccount(
                walletID: identity.walletID
            )
        #expect(accountBeforeInitialization == nil)
        let initialized = try await database.ensureBitcoinSilentPaymentAccount(
            walletID: identity.walletID,
            vault: vault
        )
        #expect(initialized)
        let initializedAccount = try await database
            .bitcoinSilentPaymentAccount(
                walletID: identity.walletID
            )
        let account = try #require(
            initializedAccount
        )
        let material = try await database.bitcoinSilentPaymentKeyMaterial(
            walletID: identity.walletID,
            vault: vault
        )
        #expect(material.address == account.address.encoded)
        #expect(
            material.scanPrivateKey.hexString
                == "78e7fd7d2b7a2c1456709d147021a122d2dccaafeada040cc1002083e2833b09"
        )
        #expect(
            material.spendPrivateKey.hexString
                == "c88567742d5019d7ccc81f6e82cef8ef01997a6a3761cc9166036b580549539b"
        )
        #expect(
            material.address
                == "sp1qqfqnnv8czppwysafq3uwgwvsc638hc8rx3hscuddh0xa2yd746s7xqh6yy"
                    + "9ncjnqhqxazct0fzh98w7lpkm5fvlepqec2yy0sxlq4j6ccc3h6t0g"
        )

        let accountColumns = try await database.pool.read { rawDatabase in
            try Row.fetchAll(
                rawDatabase,
                sql: "PRAGMA table_info(bitcoinSilentPaymentAccounts)"
            ).compactMap { row in row["name"] as String? }
        }
        let outputColumns = try await database.pool.read { rawDatabase in
            try Row.fetchAll(
                rawDatabase,
                sql: "PRAGMA table_info(bitcoinSilentPaymentOutputs)"
            ).compactMap { row in row["name"] as String? }
        }
        #expect(accountColumns.contains("keychainReference"))
        #expect(outputColumns.contains("keychainReference"))
        #expect(!accountColumns.contains("scanPrivateKey"))
        #expect(!accountColumns.contains("spendPrivateKey"))
        #expect(!outputColumns.contains("privateKey"))

        let matches = try BitcoinSilentPaymentCrypto.locateOutputs(
            keyMaterial: BitcoinSilentPaymentKeyMaterial(
                version: BitcoinSilentPaymentKeyMaterial.currentVersion,
                walletID: identity.walletID,
                scanPrivateKey: try Self.data(
                    "0f694e068028a717f8af6b9411f9a133dd3565258714cc226594b34db90c1f2c"
                ),
                spendPrivateKey: try Self.data(
                    "9d6ad855ce3417ef84e836892e5a56392bfba05fa5d97ccea30e266f540e08b3"
                ),
                address: Self.vectorAddress
            ),
            tweakPublicKey: try Self.data(
                "024ac253c216532e961988e2a8ce266a447c894c781e52ef6cee902361db960004"
            ),
            transactionOutputs: [
                Data([0x51, 0x20]) + (try Self.data(
                    "3e9fce73d4e77a4809908e3c3a2e54ee147b9312dc5044a193d1fc85de46e3c1"
                ))
            ]
        )
        let owned = try #require(matches.first)
        let hash = String(repeating: "ab", count: 32)
        try await database.saveBitcoinSilentPaymentOutput(
            walletID: identity.walletID,
            transactionHash: hash,
            outputIndex: owned.outputIndex,
            valueAtomic: try BitcoinFamilyAtomicInteger(
                validating: "125000"
            ),
            ownedKey: owned,
            blockHeight: nil,
            blockTimestamp: nil,
            vault: vault
        )
        #expect(
            try await database.bitcoinSilentPaymentOutputPrivateKey(
                walletID: identity.walletID,
                transactionHash: hash,
                outputIndex: owned.outputIndex,
                vault: vault
            ) == owned.privateKey
        )
        let exportAuthorization = try await database
            .authorizeUnprotectedSecretExport(walletID: identity.walletID)
        #expect(
            try await database
                .bitcoinSilentPaymentOutputPrivateKeyForExport(
                    walletID: identity.walletID,
                    transactionHash: hash,
                    outputIndex: owned.outputIndex,
                    authorization: exportAuthorization,
                    vault: vault
                ) == owned.privateKey
        )
        let exported = try await database.bitcoinSilentPaymentOutputDescriptorForExport(
            walletID: identity.walletID, transactionHash: hash, outputIndex: owned.outputIndex,
            authorization: exportAuthorization, vault: vault
        )
        let importedOutputAddress = try BitcoinPrivateDescriptor(exported).address()
        #expect(importedOutputAddress.scriptPubKey == owned.scriptPubKey)
        let imported = try PrivateKeyImportService.importKey(exported, network: .bitcoin)
        #expect(imported.address == importedOutputAddress.address)
        let exports = try await database.bitcoinSilentPaymentPrivateKeyExportEntries(
            walletID: identity.walletID, authorization: exportAuthorization, vault: vault
        )
        #expect(exports.count == 1 && exports.first?.descriptor == exported)
        let output = try #require(
            await database.bitcoinSilentPaymentOutputs(
                walletID: identity.walletID
            ).first
        )
        #expect(output.valueAtomic.decimalText == "125000")
        #expect(output.blockHeight == nil)
        #expect(!output.isSpent)
        let cached = try await BitcoinSilentPaymentSyncService(
            database: database
        ).cachedResult(walletID: identity.walletID)
        #expect(cached.balanceAtomic.decimalText == "125000")

        let checkpointStart = account.lastScanHeight
        try await database.beginBitcoinSilentPaymentScan(
            walletID: identity.walletID,
            targetHeight: checkpointStart + 2
        )
        try await database.updateBitcoinSilentPaymentScanHeight(
            walletID: identity.walletID,
            height: checkpointStart + 1
        )
        let partialCheckpoint = try #require(
            await database.bitcoinSilentPaymentAccount(
                walletID: identity.walletID
            )
        )
        #expect(partialCheckpoint.lastScanHeight == checkpointStart + 1)
        #expect(partialCheckpoint.scanTargetHeight == checkpointStart + 2)
        try await database.updateBitcoinSilentPaymentScanHeight(
            walletID: identity.walletID,
            height: checkpointStart + 2
        )
        let completeCheckpoint = try #require(
            await database.bitcoinSilentPaymentAccount(
                walletID: identity.walletID
            )
        )
        #expect(completeCheckpoint.lastScanHeight == checkpointStart + 2)

        try await database.markBitcoinSilentPaymentOutputOrphaned(
            walletID: identity.walletID,
            transactionHash: hash,
            outputIndex: owned.outputIndex
        )
        let orphaned = try #require(
            await database.bitcoinSilentPaymentOutputs(
                walletID: identity.walletID
            ).first
        )
        #expect(orphaned.isSpent)
        #expect(try await database.bitcoinSilentPaymentPrivateKeyExportEntries(
            walletID: identity.walletID, authorization: exportAuthorization, vault: vault
        ).isEmpty)
        await #expect(throws: BitcoinSilentPaymentDatabaseError.invalidOutput) {
            try await database.bitcoinSilentPaymentOutputDescriptorForExport(
                walletID: identity.walletID, transactionHash: hash, outputIndex: owned.outputIndex,
                authorization: exportAuthorization, vault: vault
            )
        }

        #expect(orphaned.spentByTransactionHash == nil)
        try await database.restoreBitcoinSilentPaymentOutputUnspent(
            walletID: identity.walletID,
            transactionHash: hash,
            outputIndex: owned.outputIndex
        )
        let restored = try #require(
            await database.bitcoinSilentPaymentOutputs(
                walletID: identity.walletID
            ).first
        )
        #expect(!restored.isSpent)
    }


    struct Vector: Decodable {
        let index: Int
        let descriptor: String
        let address: String
        let script: String
        let bip86: String
    }

    // Bitcoin Core 28.3 deriveaddresses/validateaddress, mainnet format.
    // Reproducible public fixture keys are deliberately unfunded and cover both Y parities.
    static func vector(_ index: Int) throws -> Vector {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BitcoinImport/rawtr-core-28.3.json")
        return try #require(JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
            .first { $0.index == index })
    }

    @Test(arguments: 1...8)
    func importsExactCoreOutputThroughTextFilesAndBackup(index: Int) async throws {
        let vector = try Self.vector(index)
        let parsed = try BitcoinPrivateDescriptor(vector.descriptor)
        let owner = try parsed.address(sourceID: "0")
        #expect(owner.address == vector.address)
        #expect(owner.scriptPubKey.hexString == vector.script)
        #expect(owner.address != vector.bip86)
        #expect(parsed.script == .rawtr)
        let draft = try PrivateKeyImportService.importKey(vector.descriptor, network: .bitcoin)
        #expect(draft.address == vector.address)
        let document = BitcoinBase64ImportTests.document(key: parsed.key)
        #expect(try PrivateKeyImportService.importKey(document, network: .bitcoin) == draft)
        #expect(try ImportCredentialScanReview.parse(document, mode: .privateKey(.bitcoin)).derivedAddress == vector.address)
        let formats = [vector.descriptor, "descriptor,label\n" + vector.descriptor + ",Output",
                       "[\"" + vector.descriptor + "\"]", document]
        for format in formats {
            let imported = try await BitcoinImportFileParser.shared.parse(Data(format.utf8))
            #expect(imported.sources.count == 1)
            #expect(try imported.primaryAddress().address == vector.address)
            #expect(try BitcoinImportedWalletMaterial.decode(imported.encoded()) == imported)
        }
        let material = try BitcoinImportedWalletMaterial(sources: [.init(descriptor: parsed)]).validated()
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(service: "rawtr-public-fixture.\(UUID())")
        defer { try? vault.deleteAll() }
        let restoredDraft = try PrivateKeyImportService.importKey(document, network: .bitcoin)
        let identity = try await database.persistImportedWallet(draft: restoredDraft, security: .reuseExistingProfile, vault: vault)
        #expect(try await database.bitcoinImportedMaterial(walletID: identity.walletID, vault: vault) == material)
        let addresses = try await database.bitcoinImportedAddresses(walletID: identity.walletID, material: material)
        #expect(addresses == [owner])
        // Feed balance/history for the original output script, not a newly tweaked address.
        let history = try JSONDecoder().decode(JSONValue.self, from: Data(
            ("[{\"tx_hash\":\"" + String(repeating: "ab", count: 32) + "\",\"height\":900000}]").utf8))
        let balance = try JSONDecoder().decode(JSONValue.self, from:
            BitcoinFamilyLosslessJSON.preservingNumberLexemes(in: Data(
                #"{"confirmed":125000,"unconfirmed":0}"#.utf8)))
        var transactions = Set<BitcoinHDTransactionReference>()
        let state = BitcoinHDAddressState(derived: owner, isUsed: false, isReserved: false,
            confirmedBalanceAtomic: .zero, unconfirmedBalanceAtomic: .zero)
        let discovered = try BitcoinHDDiscoveryService.parse(states: [state],
            histories: [.init(parameter: owner.scriptHash, value: history)],
            balances: [.init(parameter: owner.scriptHash, value: balance)], transactions: &transactions)
        #expect(discovered.first?.balanceAtomic.decimalText == "125000")
        #expect(discovered.first?.isUsed == true && transactions.count == 1)

        #expect(try await database.bitcoinImportedWalletOwnsAddress(walletID: identity.walletID, address: vector.address, vault: vault))
        let receive = try await database.bitcoinImportedReceiveAddress(walletID: identity.walletID, material: material, type: .bip86)
        #expect(receive.address == vector.address)
        let payload = WalletCloudBackupPayload(version: 2, walletName: "Output", walletKind: ManagedWalletKind.importedPrivateKey.rawValue,
            address: draft.address, secret: try material.encoded(), hasPassphrase: nil,
            privateKeyNetwork: "bitcoin", privateKeyFormat: BitcoinImportedWalletMaterial.accountMarker, createdAt: 0, backedUpAt: 0)
        #expect(try ICloudWalletRestoreValidator.validate(payload).draft == draft)
        try DeviceMigrationAccountSecretVerifier.validate(source: database.pool,
            secrets: [.init(walletID: identity.walletID, kind: .bitcoinImportedWallet, data: try material.encoded())])
    }

    @Test(arguments: 1...8, [false, true])
    func signsForFinalOutputKeyWithoutSecondTweak(index: Int, wrapped: Bool) throws {
        let vector = try Self.vector(index)
        let encodedKey = wrapped ? BitcoinBase64ImportTests.document(key: try BitcoinPrivateDescriptor(vector.descriptor).key) : vector.descriptor
        guard case let .bitcoinImportedWallet(material) = try PrivateKeyImportService.importKey(encodedKey, network: .bitcoin).secret else {
            Issue.record("Expected imported Bitcoin material")
            return
        }
        let owner = try material.primaryAddress()
        let output = BitcoinOPReturnSigningFixture.output(owner: owner, index: 0)
        let recipient = try BitcoinOPReturnSigningFixture(types: [.bip84])
        let options = SendBitcoinFamilyOptions(coinSelection: .manual([output]), replaceByFee: true)
        let draft = recipient.draft(options: options, usesMaximumBalance: false)
        let fee = SendResolvedNetworkFee(model: .utxoPerVByte, primaryValue: "2", secondaryValue: nil)
        let signed = try BitcoinSilentPaymentTransactionSigner.signImportedWallet(
            draft: draft, material: material, outputs: [output], requestedAtomic: 50_000,
            byteFee: 2, fee: fee, options: options, changeAddress: owner.address, recipientAddress: recipient.recipient)
        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        let input = try #require(transaction.inputs.first)
        #expect(transaction.inputs.count == 1 && input.witness.count == 1 && input.script.isEmpty)
        let digest = BitcoinImportSigningTests.taprootDigest(inputs: [output], signingIndex: 0,
            sequence: input.sequence, outputs: transaction.outputs)
        let signature = try P256K.Schnorr.SchnorrSignature(dataRepresentation: #require(input.witness.first))
        let key = P256K.Schnorr.XonlyKey(dataRepresentation: Data(owner.scriptPubKey.suffix(32)))
        #expect(key.isValidSignature(signature, for: HashDigest(Array(digest))))
        #expect(transaction.outputs.reduce(Int64(0)) { $0 + $1.value } + Int64(signed.feeAtomic)! == 100_000)
        #expect(Int64(signed.feeAtomic)! >= Int64((transaction.weight + 3) / 4) * 2)
    }

    @Test
    func rejectsAlteredChecksumsAndUncompressedOutputKeys() throws {
        let vector = try Self.vector(1)
        #expect(throws: BitcoinImportError.checksumMismatch) {
            try BitcoinPrivateDescriptor(vector.descriptor + "x")
        }
        let key = try BitcoinPrivateDescriptor(vector.descriptor).privateKey()
        let wif = try BitcoinImportKeyEncoding.encode(.init(key: key, compressed: false))
        #expect(throws: BitcoinImportError.invalidDescriptor) { try BitcoinPrivateDescriptor("rawtr(\(wif))") }
        // A bare WIF retains its existing BlueWallet-compatible policy set.
        let addresses = try BitcoinHDDerivationService().singleKeyAddresses(privateKeyData: key, format: .wifCompressed)
        #expect(Set(addresses.map(\.addressType)) == Set([.bip44, .bip49, .bip84, .bip86]))
        #expect(!addresses.contains { $0.address == vector.address })
    }
}

#if APERTURE_RAWTR_LIVE_TESTS
/// Explicit opt-in only. The private input comes from a one-shot loopback
/// harness, never source control, environment arguments or a fixture file.
struct BitcoinRawTaprootLiveTests {
    @Test
    func importsAndDiscoversFundedOutputThenVerifiesSignatureWithoutBroadcast() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "http://127.0.0.1:18457/rawtr-once"))
        let (data, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let descriptor = try #require(String(data: data, encoding: .utf8))
        let expectedAddress = "bc1pwl0jsnajmpxq9gtw6vwvjh3py2w9w0ypnzhs5zh3ku6ea0nxxz8qdnhkhk"
        let expectedHash = "58362931e633e36428637fc0964f487212259474caaa9ff8de5b85365b2a8291"
        let parsed = try BitcoinPrivateDescriptor(descriptor)
        #expect(parsed.script == .rawtr)
        let draft = try PrivateKeyImportService.importKey(descriptor, network: .bitcoin)
        #expect(draft.address == expectedAddress)
        let scan = try ImportCredentialScanReview.parse(descriptor, mode: .privateKey(.bitcoin))
        #expect(scan.derivedAddress == expectedAddress)
        let material = try await BitcoinImportFileParser.shared.parse(data)
        let owner = try material.primaryAddress()
        #expect(owner.address == expectedAddress)
        #expect(owner.scriptPubKey.hexString == "512077df284fb2d84c02a16ed31cc95e21229c573c8198af0a0af1b7359ebe66308e")
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(service: "rawtr-live-test.\(UUID())")
        defer { try? vault.deleteAll() }
        let identity = try await database.persistImportedWallet(
            draft: draft, security: .reuseExistingProfile, vault: vault)
        let stored = try await database.bitcoinImportedMaterial(walletID: identity.walletID, vault: vault)
        let restored = try #require(stored)
        #expect(try restored.primaryAddress().address == expectedAddress)
        let discovered = try await BitcoinImportedDiscoveryService(database: database, electrum: .shared)
            .discover(walletID: identity.walletID, material: restored)
        #expect(discovered.balanceAtomic.decimalText == "37662")
        #expect(discovered.receiveAddress.address == expectedAddress)
        #expect(discovered.transactions.contains { $0.transactionHash == expectedHash })
        async let rawOutputs = BitcoinFamilyElectrumClient.shared.call(chain: .bitcoin,
            method: "blockchain.scripthash.listunspent", params: [AnyEncodable(owner.scriptHash)])
        async let tip = BitcoinFamilyElectrumClient.shared.call(chain: .bitcoin,
            method: "blockchain.headers.subscribe")
        let outputs = try await SendBitcoinUTXORepository.parse(
            outputs: rawOutputs, tip: tip, chain: .bitcoin, owner: owner)
        #expect(outputs.count == 1)
        let output = try #require(outputs.first)
        #expect(output.outpoint.transactionHash == expectedHash && output.outpoint.outputIndex == 0)
        #expect(output.valueAtomic == "37662" && output.confirmations > 0)
        let options = SendBitcoinFamilyOptions(coinSelection: .manual(outputs), replaceByFee: true)
        let template = try BitcoinOPReturnSigningFixture(types: [.bip84])
        let sendDraft = template.draft(options: options, usesMaximumBalance: false)
        // Both destinations are the user's existing output address. This signed
        // transaction stays in memory and is never passed to a broadcaster.
        let signed = try BitcoinSilentPaymentTransactionSigner.signImportedWallet(
            draft: sendDraft, material: restored, outputs: outputs, requestedAtomic: 20_000,
            byteFee: 2, fee: .init(model: .utxoPerVByte, primaryValue: "2", secondaryValue: nil),
            options: options, changeAddress: owner.address, recipientAddress: owner.address)
        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        let input = try #require(transaction.inputs.first)
        #expect(transaction.inputs.count == 1 && input.witness.count == 1)
        let digest = BitcoinImportSigningTests.taprootDigest(inputs: outputs, signingIndex: 0,
            sequence: input.sequence, outputs: transaction.outputs)
        let signature = try P256K.Schnorr.SchnorrSignature(dataRepresentation: #require(input.witness.first))
        let key = P256K.Schnorr.XonlyKey(dataRepresentation: Data(owner.scriptPubKey.suffix(32)))
        #expect(key.isValidSignature(signature, for: HashDigest(Array(digest))))
        #expect(transaction.outputs.allSatisfy { $0.script == owner.scriptPubKey })
        #expect(transaction.outputs.reduce(Int64(0)) { $0 + $1.value } + Int64(signed.feeAtomic)! == 37_662)
    }
}
#endif
