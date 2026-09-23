import CoreGraphics
import Foundation

struct MuunEmergencyKitPayload: Sendable {
    let firstEncryptedKey: MuunEncryptedPrivateKey
    let secondEncryptedKey: MuunEncryptedPrivateKey
    let expectedFingerprints: MuunRecoveryFingerprints?
    let expectedRecoveryCodeChecksum: String?

    func recover(recoveryCode: String) throws -> MuunRecoveryKeyMaterial {
        try MuunRecoveryKeyDecryptor.recover(
            first: firstEncryptedKey,
            second: secondEncryptedKey,
            recoveryCode: recoveryCode,
            expectedFingerprints: expectedFingerprints,
            expectedRecoveryCodeChecksum: expectedRecoveryCodeChecksum
        )
    }
}

enum MuunEmergencyKitPDFReader {
    private static let metadataName = "metadata.json"
    private static let maximumMetadataBytes = 2 * 1_024 * 1_024

    static func read(data: Data) throws -> MuunEmergencyKitPayload {
        guard !data.isEmpty,
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              !document.isEncrypted || document.isUnlocked else {
            throw MuunRecoveryError.invalidEmergencyKit
        }
        let attachments = try embeddedFiles(in: document)
        guard attachments.count == 1,
              let metadata = attachments[metadataName],
              !metadata.isEmpty,
              metadata.count <= maximumMetadataBytes else {
            throw MuunRecoveryError.invalidEmergencyKit
        }
        return try decodeMetadata(metadata)
    }

    static func read(url: URL) throws -> MuunEmergencyKitPayload {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= 50 * 1_024 * 1_024 else {
            throw MuunRecoveryError.invalidEmergencyKit
        }
        return try read(data: Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    private static func decodeMetadata(
        _ data: Data
    ) throws -> MuunEmergencyKitPayload {
        let metadata: Metadata
        do {
            metadata = try JSONDecoder().decode(Metadata.self, from: data)
        } catch {
            throw MuunRecoveryError.invalidEmergencyKit
        }
        // Version 1 was the pre-PDF, manually copied key format. Official
        // Emergency Kit PDFs start at version 2 and always carry descriptors;
        // requiring them is what lets us reject a syntactically valid but
        // incorrect Recovery Code before a wallet is persisted.
        guard (2...3).contains(metadata.version),
              (0...Int(UInt16.max)).contains(metadata.birthdayBlock),
              metadata.encryptedKeys.count == 2,
              !metadata.outputDescriptors.isEmpty,
              metadata.outputDescriptors.count <= 16,
              metadata.outputDescriptors.allSatisfy({ $0.utf8.count <= 2_048 })
        else {
            throw MuunRecoveryError.invalidEmergencyKit
        }
        let keys = try metadata.encryptedKeys.map { key in
            guard let publicKey = Data(bitcoinHex: key.dhPubKey),
                  let ciphertext = Data(bitcoinHex: key.encryptedPrivKey),
                  let salt = Data(bitcoinHex: key.salt) else {
                throw MuunRecoveryError.invalidEmergencyKit
            }
            return try MuunEncryptedPrivateKey(
                birthdayBlock: metadata.birthdayBlock,
                ephemeralPublicKey: publicKey,
                ciphertext: ciphertext,
                salt: salt
            )
        }
        guard let fingerprints = try MuunOutputDescriptorValidator.fingerprints(
            in: metadata.outputDescriptors
        ) else {
            throw MuunRecoveryError.invalidEmergencyKit
        }
        let recoveryCodeChecksum: String?
        if let value = metadata.rcChecksum, !value.isEmpty {
            let normalized = value.lowercased(
                with: Locale(identifier: "en_US_POSIX")
            )
            guard normalized.utf8.count == 16,
                  let checksumData = Data(bitcoinHex: normalized),
                  checksumData.count == 8 else {
                throw MuunRecoveryError.invalidEmergencyKit
            }
            recoveryCodeChecksum = normalized
        } else {
            recoveryCodeChecksum = nil
        }
        return MuunEmergencyKitPayload(
            firstEncryptedKey: keys[0],
            secondEncryptedKey: keys[1],
            expectedFingerprints: fingerprints,
            expectedRecoveryCodeChecksum: recoveryCodeChecksum
        )
    }

    private static func embeddedFiles(
        in document: CGPDFDocument
    ) throws -> [String: Data] {
        guard let catalog = document.catalog else {
            throw MuunRecoveryError.invalidEmergencyKit
        }
        var namesDictionary: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(
            catalog,
            "Names",
            &namesDictionary
        ), let namesDictionary else {
            return [:]
        }
        var embeddedFilesDictionary: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(
            namesDictionary,
            "EmbeddedFiles",
            &embeddedFilesDictionary
        ), let embeddedFilesDictionary else {
            return [:]
        }
        var results: [String: Data] = [:]
        try collectNameTree(
            embeddedFilesDictionary,
            depth: 0,
            results: &results
        )
        return results
    }

    private static func collectNameTree(
        _ dictionary: CGPDFDictionaryRef,
        depth: Int,
        results: inout [String: Data]
    ) throws {
        guard depth <= 16, results.count <= 16 else {
            throw MuunRecoveryError.invalidEmergencyKit
        }
        var names: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Names", &names),
           let names {
            let count = CGPDFArrayGetCount(names)
            guard count.isMultiple(of: 2), count <= 32 else {
                throw MuunRecoveryError.invalidEmergencyKit
            }
            var index = 0
            while index < count {
                var nameReference: CGPDFStringRef?
                var fileSpecification: CGPDFDictionaryRef?
                guard CGPDFArrayGetString(
                    names,
                    index,
                    &nameReference
                ), let nameReference,
                      CGPDFArrayGetDictionary(
                          names,
                          index + 1,
                          &fileSpecification
                      ), let fileSpecification,
                      let copiedName = CGPDFStringCopyTextString(nameReference)
                else {
                    throw MuunRecoveryError.invalidEmergencyKit
                }
                let name = copiedName as String
                guard results[name] == nil else {
                    throw MuunRecoveryError.invalidEmergencyKit
                }
                results[name] = try attachmentData(fileSpecification)
                index += 2
            }
        }
        var kids: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Kids", &kids),
           let kids {
            let count = CGPDFArrayGetCount(kids)
            guard count <= 16 else {
                throw MuunRecoveryError.invalidEmergencyKit
            }
            for index in 0..<count {
                var child: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(kids, index, &child),
                      let child else {
                    throw MuunRecoveryError.invalidEmergencyKit
                }
                try collectNameTree(
                    child,
                    depth: depth + 1,
                    results: &results
                )
            }
        }
    }

    private static func attachmentData(
        _ fileSpecification: CGPDFDictionaryRef
    ) throws -> Data {
        var embeddedFileDictionary: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(
            fileSpecification,
            "EF",
            &embeddedFileDictionary
        ), let embeddedFileDictionary else {
            throw MuunRecoveryError.invalidEmergencyKit
        }
        var stream: CGPDFStreamRef?
        let found = CGPDFDictionaryGetStream(
            embeddedFileDictionary,
            "UF",
            &stream
        ) || CGPDFDictionaryGetStream(
            embeddedFileDictionary,
            "F",
            &stream
        )
        guard found, let stream else {
            throw MuunRecoveryError.invalidEmergencyKit
        }
        var format = CGPDFDataFormat.raw
        guard let copied = CGPDFStreamCopyData(stream, &format) else {
            throw MuunRecoveryError.invalidEmergencyKit
        }
        let result = copied as Data
        guard result.count <= maximumMetadataBytes else {
            throw MuunRecoveryError.invalidEmergencyKit
        }
        return result
    }
}

private extension MuunEmergencyKitPDFReader {
    struct Metadata: Decodable {
        let version: Int
        let birthdayBlock: Int
        let encryptedKeys: [MetadataKey]
        let outputDescriptors: [String]
        let rcChecksum: String?
    }

    struct MetadataKey: Decodable {
        let dhPubKey: String
        let encryptedPrivKey: String
        let salt: String
    }
}

private enum MuunOutputDescriptorValidator {
    private static let inputCharacters = Array(
        "0123456789()[],'/*abcdefgh@:$%{}IJKLMNOPQRSTUVWXYZ&+-.;<=>?!^_|~"
            + "ijklmnopqrstuvwxyzABCDEFGH`#\"\\ "
    )
    private static let checksumCharacters = Array(
        "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    )
    private static let fingerprintExpression = try? NSRegularExpression(
        pattern: #"([0-9A-Fa-f]{8})/1'/1'"#
    )

    static func fingerprints(
        in descriptors: [String]
    ) throws -> MuunRecoveryFingerprints? {
        guard !descriptors.isEmpty else { return nil }
        guard let expression = fingerprintExpression else {
            throw MuunRecoveryError.invalidEmergencyKit
        }
        var expected: MuunRecoveryFingerprints?
        for value in descriptors {
            let parts = value.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2,
                  String(parts[1]) == checksum(for: String(parts[0])) else {
                throw MuunRecoveryError.invalidEmergencyKit
            }
            let descriptor = String(parts[0])
            let range = NSRange(descriptor.startIndex..., in: descriptor)
            let matches = expression.matches(in: descriptor, range: range)
            guard matches.count == 2,
                  let firstRange = Range(matches[0].range(at: 1), in: descriptor),
                  let secondRange = Range(matches[1].range(at: 1), in: descriptor)
            else {
                throw MuunRecoveryError.invalidEmergencyKit
            }
            let fingerprints = try MuunRecoveryFingerprints(
                user: String(descriptor[firstRange]),
                muun: String(descriptor[secondRange])
            )
            if let expected, expected != fingerprints {
                throw MuunRecoveryError.invalidEmergencyKit
            }
            expected = fingerprints
        }
        return expected
    }

    private static func checksum(for descriptor: String) -> String {
        var checksum: UInt64 = 1
        var characterClass = 0
        var classCount = 0
        for character in descriptor {
            guard let position = inputCharacters.firstIndex(of: character) else {
                return ""
            }
            checksum = polymod(checksum, position & 31)
            characterClass = characterClass * 3 + (position >> 5)
            classCount += 1
            if classCount == 3 {
                checksum = polymod(checksum, characterClass)
                characterClass = 0
                classCount = 0
            }
        }
        if classCount > 0 {
            checksum = polymod(checksum, characterClass)
        }
        for _ in 0..<8 { checksum = polymod(checksum, 0) }
        checksum ^= 1
        return String((0..<8).map {
            checksumCharacters[Int((checksum >> UInt64(5 * (7 - $0))) & 31)]
        })
    }

    private static func polymod(_ checksum: UInt64, _ value: Int) -> UInt64 {
        let top = checksum >> 35
        var result = ((checksum & 0x7_ffff_ffff) << 5) ^ UInt64(value)
        let generators: [UInt64] = [
            0xf5dee51989,
            0xa9fdca3312,
            0x1bab10e32d,
            0x3706b1677a,
            0x644d626ffd,
        ]
        for index in 0..<5 where top >> index & 1 != 0 {
            result ^= generators[index]
        }
        return result
    }
}
