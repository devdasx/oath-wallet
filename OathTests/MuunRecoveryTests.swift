import Foundation
import GRDB
import P256K
import Testing
@testable import Aperture

@Suite(.serialized)
struct MuunRecoveryTests {
    static let recoveryCode =
        "LA2Q-48Z3-25JR-S5JB-5SUS-HXHJ-RCMM-8YUA"
    static let firstEncryptedKey =
        "5TnX1czXD6sQEPbpjNANzkwS9XSgRdv3Kk7Z5UuaJSa9WUUwK74cebE3oN2or9jc"
        + "wAGMVtWVDgTubeYWS44uAMTrAC46dcEtpfK5adYA7QbZnJASci9STGG74Yu1LUSw"
        + "L6veJ8SJeakHPWH3wXC"
    static let secondEncryptedKey =
        "5TnX1vYSm7mQVFu76ftUDBcowWnq153iYkAx59TdGD2Z4EU4QzBiHTxSHKKVEXRJ"
        + "GhLy9omLa3kmT94A5E58Fe4tHMvdG5U6zN5z4YWLeroYbUak27kJDs3Gsz7a4vwx"
        + "qNYeUWTxKLi3qXagR1Q"

    @Test
    func recoveryCodeKDFMatchesOfficialV1AndV2Vectors() throws {
        let salt = try #require(Data(hexString: "ffffffff"))
        let v1 = try MuunRecoveryCode.challengePrivateKey(
            code: "R52Q-48Z3-25JR-S5JB-5SUS-HXHJ-RCMM-8YUA",
            legacySalt: salt
        )
        let v2 = try MuunRecoveryCode.challengePrivateKey(
            code: Self.recoveryCode,
            legacySalt: salt
        )
        #expect(
            v1.hexString
                == "ade3fe99c608fd04484bce1ccf2889a5096f68f4b6b459e7f9ee9f0ada0a2782"
        )
        #expect(
            v2.hexString
                == "0e1446153d4cafb073110739608fdd76b8712221476ec198cf35e1d74d274e83"
        )

        let checksum = try MuunRecoveryCode.challengePublicKeyChecksum(
            code: "3V4N-R9EC-V3TQ-NRB3-Q7NY-9HXP-CSDC-B5BC",
            legacySalt: try #require(Data(hexString: "63f701fda4fc0b0c"))
        )
        #expect(checksum == "7fd1c538e6d40bad")
    }

    @Test
    func recoveryCodeNormalizationAndValidationAreExact() throws {
        #expect(
            try MuunRecoveryCode.canonical(
                " la2q 48z3 25jr s5jb 5sus hxhj rcmm 8yua\n"
            ) == Self.recoveryCode
        )
        #expect(throws: MuunRecoveryError.invalidRecoveryCode) {
            try MuunRecoveryCode.canonical(
                "LA2Q-48Z3-25JR-S5JB-5SUS-HXHJ-RCMM-8YU0"
            )
        }
        #expect(throws: MuunRecoveryError.unsupportedRecoveryCodeVersion) {
            try MuunRecoveryCode.canonical(
                "LB2Q-48Z3-25JR-S5JB-5SUS-HXHJ-RCMM-8YUA"
            )
        }
    }

    @Test
    func encryptedKeyDecoderMatchesOfficialSaltedAndLegacyVectors() throws {
        let salted = try MuunEncryptedPrivateKey(encoded:
            "4LbSKwcepbbx4dPetoxvTWszb6mLyJHFhumzmdPRVprbn8XZBvFa6Ffarm6R3WGK"
            + "utFzdxxJgQDdSHuYdjhDp1EZfSNbj12gXMND1AgmNijSxEua3LwVURU3nzWsvV5b"
            + "1AsWEjJca24CaFY6T3C"
        )
        #expect(salted.birthdayBlock == 376)
        #expect(
            salted.ephemeralPublicKey.hexString
                == "020a8d322dda8ff685d80b16681d4e87c109664cdc246a9d3625adfe0de203e71e"
        )
        #expect(salted.salt.hexString == "e3305526d0cd675f")
        #expect(salted.carriesSalt)

        let legacy = try MuunEncryptedPrivateKey(encoded:
            "5XEEts6mc9WV34krDWsqmpLcPCw2JkK8qJu3gFdZpP8ngkERuQEsaDvYrGkhXUpM"
            + "6jQRtimTYm4XnBPujpo3MsdYBedsNVxvT3WC6uCCFuzNUZCoydVY39yJXbxva7naD"
            + "xH5iTra"
        )
        #expect(!legacy.carriesSalt)
        #expect(legacy.salt == Data(repeating: 0, count: 8))

        let version3 = try MuunEncryptedPrivateKey(encoded:
            "FwBs2Fh3TCTMhTg9DNrr3MuiGhVmiNGeqpg8Zubo8mbZkYpNejJZkmsTU7iJNXEt"
            + "xmWDVXaF8auAaQhFj8oMH5BhfLAdieLVAuy59RGHsCvEwzubbY7dzqYvpcSfWypz"
            + "cERHxKVTMmjqwtTK"
        )
        #expect(version3.birthdayBlock == 0)
        #expect(
            version3.ephemeralPublicKey.hexString
                == "03ab02bfb3f61a213d2c4ea980689fea20a866d718e6d009f1149f074ba00bc066"
        )
        #expect(
            version3.ciphertext.hexString
                == "0ce3ff52d4bb35e99f0868585342cc7f95c7b282c9b57ab44177b3caeb5a5177"
                + "972ced426cfc09d38703d3f2ec623fcd202456b4d5238cd7707c284182161e44"
        )
        #expect(version3.salt.hexString == "6675492c525f1ed2")
        #expect(version3.carriesSalt)
    }

    @Test
    func officialLibraryFixtureDecryptsAndDerivesEveryRecoveryAddress()
        throws
    {
        let fingerprints = try MuunRecoveryFingerprints(
            user: "0a1fe5a0",
            muun: "970a3fba"
        )
        let material = try MuunRecoveryKeyDecryptor.recover(
            firstEncryptedKey: Self.firstEncryptedKey,
            secondEncryptedKey: Self.secondEncryptedKey,
            recoveryCode: Self.recoveryCode,
            expectedFingerprints: fingerprints
        )
        #expect(material.birthdayBlock == 44_640)

        try assertAddresses(
            material: material,
            branch: .change,
            contactIndex: nil,
            expected: [
                .v2: "32erc8ydc2Pbostrr6biTiXNKoTH7x3zVU",
                .v3: "3AC8CrA2EB5fTwqDj9aSpAjtH8HiEXXMSV",
                .v4: "bc1qz53c72gw9xg2n4zursr074httsfthqnf48alr5perl6kwrpmgffsxgml0s",
                .v5: "bc1pz5fetqgr20fv8er7932hzuxgukn4adm35mxf0lqapaane7ks0epq2xp8rj",
            ]
        )
        try assertAddresses(
            material: material,
            branch: .external,
            contactIndex: nil,
            expected: [
                .v2: "3JCoWCH5BdTDE3FXeDJjTk65BZ6MN9GQus",
                .v3: "36j9qNmxSaMVFss6GoHCK9zwr91AhaqQJi",
                .v4: "bc1q0px38d4wrh4s2cqfvkqxhyg7a5e2zca4uk2hm0n5w74wf40270ys5w7h54",
                .v5: "bc1pzh45h47j9zj2jzz77mf290fd3acu8erkpwhcczr8k4hk0hd3uw2qyy08rd",
            ]
        )
        try assertAddresses(
            material: material,
            branch: .contacts,
            contactIndex: 0,
            expected: [
                .v2: "3BN3Hw6WYP2T1p9rdZa3qag64AiuXMnFNg",
                .v3: "38AZdZVrT6u9buLxFovuXdMTEoyfp5GvPb",
                .v4: "bc1qsx05349h4m0fl3zqum77jqykha08sckym9lsfxmctuszemzd4fhszd9uuc",
                .v5: "bc1peuwp7zuckte8985f8sanudm93lp2grf8p5h0sy3glrtz6lrutw9q64efke",
            ]
        )
    }

    @Test
    func currentVersion3SerializedPairDecryptsToTheSameHDKeys() throws {
        let version3First =
            "FuhtSTCYwvvaKKchWuSXE2otALhDSJwiEs8ZPPJwquLs7yAeUqS9rkkYUcSrmVSK"
            + "yh4ev9LJPnpP8fdKrHUbRdB21SToVHBgC4wq1BxUTg8BVhM2rUxUeaHgsmhU59Nn"
            + "ZKxYNtokYVULCY4E"
        let version3Second =
            "Fv1SN1DSxBnsbgvRc7sCbpoEJv8M7Xwmdro7SM5QFT6rF53maUJtFEhq9zpYSpyQ"
            + "bLyumVhbFeJtnJoL5NmCTkLtY4w2hStT6YroBjQgSVJbo6kdiFZFpPiuSW9y6eeQ"
            + "ZWLa2ZZiJwVdq1YS"
        let version2Material = try MuunRecoveryKeyDecryptor.recover(
            firstEncryptedKey: Self.firstEncryptedKey,
            secondEncryptedKey: Self.secondEncryptedKey,
            recoveryCode: Self.recoveryCode
        )
        let version3Material = try MuunRecoveryKeyDecryptor.recover(
            firstEncryptedKey: version3First,
            secondEncryptedKey: version3Second,
            recoveryCode: Self.recoveryCode
        )

        #expect(version3Material.birthdayBlock == 0)
        #expect(version3Material.userPrivateKey == version2Material.userPrivateKey)
        #expect(version3Material.userChainCode == version2Material.userChainCode)
        #expect(version3Material.muunPrivateKey == version2Material.muunPrivateKey)
        #expect(version3Material.muunChainCode == version2Material.muunChainCode)
    }

    @Test
    func taprootCombinedPrivateKeyMatchesTheDerivedV5OutputKey() throws {
        let material = try MuunRecoveryKeyDecryptor.recover(
            firstEncryptedKey: Self.firstEncryptedKey,
            secondEncryptedKey: Self.secondEncryptedKey,
            recoveryCode: Self.recoveryCode
        )
        let keys = try MuunRecoveryDerivation.keys(
            material: material,
            branch: .external,
            addressIndex: 0
        )
        let outputPrivateKey = try MuunRecoveryAddressFactory
            .taprootOutputPrivateKey(
                userPrivateKey: try #require(keys.user.privateKey),
                muunPrivateKey: try #require(keys.muun.privateKey)
            )
        let signingKey = try P256K.Signing.PrivateKey(
            dataRepresentation: outputPrivateKey
        )
        let address = try MuunRecoveryAddressFactory.derive(
            material: material,
            version: .v5,
            branch: .external,
            addressIndex: 0
        )
        #expect(Data(address.scriptPubKey.suffix(32)) == Data(signingKey.publicKey.xonly.bytes))
    }

    @Test
    func importInputNormalizesAsTypedAndRequiresMatchingKeys() throws {
        #expect(
            MuunRecoveryImportInput.recoveryCode(
                "la2q 48z3-25jr s5jb 5sus hxhj rcmm 8yua"
            ) == Self.recoveryCode
        )
        #expect(
            MuunRecoveryImportInput.encryptedKey(
                " \n\(Self.firstEncryptedKey)\t"
            ) == Self.firstEncryptedKey
        )
        #expect(MuunRecoveryImportInput.manualInputsAreValid(
            firstEncryptedKey: Self.firstEncryptedKey,
            secondEncryptedKey: Self.secondEncryptedKey,
            recoveryCode: Self.recoveryCode
        ))
        #expect(!MuunRecoveryImportInput.manualInputsAreValid(
            firstEncryptedKey: Self.firstEncryptedKey,
            secondEncryptedKey: Self.secondEncryptedKey,
            recoveryCode: ""
        ))
        #expect(!MuunRecoveryImportInput.manualInputsAreValid(
            firstEncryptedKey: "",
            secondEncryptedKey: Self.secondEncryptedKey,
            recoveryCode: Self.recoveryCode
        ))
        #expect(!MuunRecoveryImportInput.manualInputsAreValid(
            firstEncryptedKey: Self.firstEncryptedKey,
            secondEncryptedKey: "",
            recoveryCode: Self.recoveryCode
        ))

        let unrelatedKey =
            "4LbSKwcepbbx4dPetoxvTWszb6mLyJHFhumzmdPRVprbn8XZBvFa6Ffarm6R3WGK"
            + "utFzdxxJgQDdSHuYdjhDp1EZfSNbj12gXMND1AgmNijSxEua3LwVURU3nzWsvV5b"
            + "1AsWEjJca24CaFY6T3C"
        #expect(!MuunRecoveryImportInput.manualInputsAreValid(
            firstEncryptedKey: Self.firstEncryptedKey,
            secondEncryptedKey: unrelatedKey,
            recoveryCode: Self.recoveryCode
        ))
    }

    @Test
    func emergencyKitPDFReadsEmbeddedMetadataAndVerifiesFingerprints()
        throws
    {
        let first = try MuunEncryptedPrivateKey(
            encoded: Self.firstEncryptedKey
        )
        let second = try MuunEncryptedPrivateKey(
            encoded: Self.secondEncryptedKey
        )
        var metadata: [String: Any] = [
            "version": 3,
            "birthdayBlock": first.birthdayBlock,
            "encryptedKeys": [first, second].map {
                [
                    "dhPubKey": $0.ephemeralPublicKey.hexString,
                    "encryptedPrivKey": $0.ciphertext.hexString,
                    "salt": $0.salt.hexString,
                ]
            },
            "outputDescriptors": [
                "sh(wsh(multi(2, 0a1fe5a0/1'/1'/0/*, "
                    + "970a3fba/1'/1'/0/*)))#8dkz9zqs",
            ],
            "rcChecksum": try MuunRecoveryCode.challengePublicKeyChecksum(
                code: Self.recoveryCode,
                legacySalt: second.salt
            ),
        ]
        let metadataData = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.sortedKeys]
        )
        let payload = try MuunEmergencyKitPDFReader.read(
            data: Self.pdf(embedding: metadataData)
        )
        let material = try payload.recover(
            recoveryCode: Self.recoveryCode
        )
        let address = try MuunRecoveryAddressFactory.derive(
            material: material,
            version: .v5,
            branch: .external,
            addressIndex: 0
        )
        #expect(
            address.address
                == "bc1pzh45h47j9zj2jzz77mf290fd3acu8erkpwhcczr8k4hk0hd3uw2qyy08rd"
        )
        #expect(throws: MuunRecoveryError.recoveryCodeDoesNotMatchEmergencyKit) {
            try payload.recover(
                recoveryCode: "LA2Q-48Z3-25JR-S5JB-5SUS-HXHJ-RCMM-8YUB"
            )
        }

        metadata["outputDescriptors"] = []
        #expect(throws: MuunRecoveryError.invalidEmergencyKit) {
            let invalidData = try JSONSerialization.data(
                withJSONObject: metadata,
                options: [.sortedKeys]
            )
            _ = try MuunEmergencyKitPDFReader.read(
                data: Self.pdf(embedding: invalidData)
            )
        }

        metadata["outputDescriptors"] = [
            "sh(wsh(multi(2, 0a1fe5a0/1'/1'/0/*, "
                + "970a3fba/1'/1'/0/*)))#8dkz9zqs",
        ]
        metadata["rcChecksum"] = "not-a-checksum"
        #expect(throws: MuunRecoveryError.invalidEmergencyKit) {
            let invalidData = try JSONSerialization.data(
                withJSONObject: metadata,
                options: [.sortedKeys]
            )
            _ = try MuunEmergencyKitPDFReader.read(
                data: Self.pdf(embedding: invalidData)
            )
        }

        metadata["version"] = 1
        metadata["rcChecksum"] = "0000000000000000"
        #expect(throws: MuunRecoveryError.invalidEmergencyKit) {
            let invalidData = try JSONSerialization.data(
                withJSONObject: metadata,
                options: [.sortedKeys]
            )
            _ = try MuunEmergencyKitPDFReader.read(
                data: Self.pdf(embedding: invalidData)
            )
        }
    }

    @Test
    func recoveredWalletPersistsOnlyOneBitcoinAccount() async throws {
        let database = try WalletDatabase.temporary()
        let material = try MuunRecoveryKeyDecryptor.recover(
            firstEncryptedKey: Self.firstEncryptedKey,
            secondEncryptedKey: Self.secondEncryptedKey,
            recoveryCode: Self.recoveryCode
        )
        let draft = try WalletCoreService.importMuunRecovery(material)
        let identity = try await database.persistImportedWallet(
            draft: draft,
            security: .reuseExistingProfile
        )
        let secretReference = try await database.pool.read { database in
            try #require(DBWalletRecord.fetchOne(
                database,
                key: identity.walletID
            )?.secretKeyReference)
        }
        defer {
            try? WalletSecretVault.shared.deleteIfPresent(
                reference: secretReference
            )
        }

        let accounts = try await database.pool.read { database in
            try DBWalletAccountRecord
                .filter(Column("walletID") == identity.walletID)
                .fetchAll(database)
        }
        #expect(accounts.count == 1)
        #expect(
            accounts.first?.networkID
                == BitcoinFamilyChain.bitcoin.networkID
        )
        #expect(
            accounts.first?.derivationPath
                == MuunRecoveryKeyMaterial.accountMarker
        )
        #expect(
            try await database.muunRecoveryWallet(
                walletID: identity.walletID
            ) != nil
        )
        #expect(try await database.muunRecoveryWalletOwnsAddress(
            walletID: identity.walletID,
            address: accounts[0].address
        ))
        #expect(!(try await database.muunRecoveryWalletOwnsAddress(
            walletID: identity.walletID,
            address: "bc1pqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqs3wf0qm"
        )))
        #expect(
            try await database.muunRecoveryKeyMaterial(
                walletID: identity.walletID,
                vault: .shared
            ) == material
        )

        let prepared = try WalletDatabase.makeDeviceMigrationExport(
            pool: database.pool,
            vault: .shared
        )
        defer {
            try? FileManager.default.removeItem(
                at: prepared.databaseURL.deletingLastPathComponent()
            )
        }
        let migrationSecret = try #require(
            prepared.secrets.walletSecrets.first
        )
        #expect(prepared.secrets.walletSecrets.count == 1)
        #expect(migrationSecret.walletID == identity.walletID)
        #expect(migrationSecret.kind == .muunRecovery)
        #expect(
            try MuunRecoveryKeyMaterial.decode(migrationSecret.data)
                == material
        )

        let destination = try WalletDatabase.temporary()
        let verified = try WalletDatabase.verifyDeviceMigration(
            DeviceMigrationIncomingPackage(
                databaseURL: prepared.databaseURL,
                manifest: prepared.manifest,
                secrets: prepared.secrets
            ),
            against: destination.pool
        )
        #expect(
            verified.contents.muunRecoveryWalletIDs
                == Set([identity.walletID])
        )
    }

    private func assertAddresses(
        material: MuunRecoveryKeyMaterial,
        branch: MuunRecoveryAddressBranch,
        contactIndex: Int?,
        expected: [MuunRecoveryAddressVersion: String]
    ) throws {
        let derived = try MuunRecoveryAddressFactory.deriveAll(
            material: material,
            branch: branch,
            contactIndex: contactIndex,
            addressIndex: 0
        )
        #expect(Dictionary(uniqueKeysWithValues: derived.map { ($0.version, $0.address) }) == expected)
    }

    private static func pdf(embedding metadata: Data) -> Data {
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles << /Names [(metadata.json) 5 0 R] >> >> >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R >>".utf8),
            Data("<< /Length 0 >>\nstream\n\nendstream".utf8),
            Data("<< /Type /Filespec /F (metadata.json) /EF << /F 6 0 R >> >>".utf8),
            Data("<< /Type /EmbeddedFile /Length \(metadata.count) >>\nstream\n".utf8)
                + metadata
                + Data("\nendstream".utf8),
        ]
        var result = Data("%PDF-1.7\n".utf8)
        var offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(result.count)
            result.append(Data("\(index + 1) 0 obj\n".utf8))
            result.append(object)
            result.append(Data("\nendobj\n".utf8))
        }
        let xrefOffset = result.count
        result.append(Data("xref\n0 \(objects.count + 1)\n".utf8))
        result.append(Data("0000000000 65535 f \n".utf8))
        for offset in offsets {
            result.append(Data(
                String(format: "%010d 00000 n \n", offset).utf8
            ))
        }
        result.append(Data(
            "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
                .utf8
        ))
        result.append(Data("startxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return result
    }
}
