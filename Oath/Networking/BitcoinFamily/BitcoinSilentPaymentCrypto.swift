import Foundation
import P256K
import WalletCore

enum BitcoinSilentPaymentCryptoError: Error, Equatable {
    case invalidKey
    case invalidOutpoint
    case invalidScalar
    case noEligibleInputs
    case outputNotFound
}

struct BitcoinSilentPaymentInputSecret: Hashable, Sendable {
    let outpoint: Data
    let privateKey: Data
    let isTaproot: Bool

    init(outpoint: Data, privateKey: Data, isTaproot: Bool) throws {
        guard outpoint.count == 36 else {
            throw BitcoinSilentPaymentCryptoError.invalidOutpoint
        }
        guard privateKey.count == 32,
              (try? P256K.Signing.PrivateKey(
                  dataRepresentation: privateKey
              )) != nil else {
            throw BitcoinSilentPaymentCryptoError.invalidKey
        }
        self.outpoint = outpoint
        self.privateKey = privateKey
        self.isTaproot = isTaproot
    }
}

struct BitcoinSilentPaymentDestination: Hashable, Sendable {
    let outputPublicKey: Data
    let scriptPubKey: Data
    let sharedSecretTweak: Data
}

struct BitcoinSilentPaymentOwnedOutputKey: Hashable, Sendable {
    let outputIndex: Int
    let outputPublicKey: Data
    let scriptPubKey: Data
    let privateKey: Data
    let label: UInt32?
    let outputCounter: UInt32
}

struct BitcoinSilentPaymentKeyMaterial: Codable, Hashable, Sendable {
    static let currentVersion = 1
    static let scanPath = "m/352'/0'/0'/1'/0"
    static let spendPath = "m/352'/0'/0'/0'/0"

    let version: Int
    let walletID: String
    let scanPrivateKey: Data
    let spendPrivateKey: Data
    let address: String

    static func derive(
        walletID: String,
        credential: WalletRecoveryCredential
    ) throws -> Self {
        guard !walletID.isEmpty,
              let wallet = credential.makeHDWallet(),
              let scan = wallet.getKey(
                  coin: .bitcoin,
                  derivationPath: scanPath
              ),
              let spend = wallet.getKey(
                  coin: .bitcoin,
                  derivationPath: spendPath
              ) else {
            throw BitcoinSilentPaymentCryptoError.invalidKey
        }
        let address = try BitcoinSilentPaymentAddress(
            scanPublicKey: scan.getPublicKeySecp256k1(
                compressed: true
            ).data,
            spendPublicKey: spend.getPublicKeySecp256k1(
                compressed: true
            ).data
        )
        return Self(
            version: currentVersion,
            walletID: walletID,
            scanPrivateKey: scan.data,
            spendPrivateKey: spend.data,
            address: address.encoded
        )
    }

    func validated() throws -> Self {
        guard version == Self.currentVersion,
              !walletID.isEmpty else {
            throw BitcoinSilentPaymentCryptoError.invalidKey
        }
        let scan = try P256K.Signing.PrivateKey(
            dataRepresentation: scanPrivateKey
        )
        let spend = try P256K.Signing.PrivateKey(
            dataRepresentation: spendPrivateKey
        )
        let expected = try BitcoinSilentPaymentAddress(
            scanPublicKey: scan.publicKey.dataRepresentation,
            spendPublicKey: spend.publicKey.dataRepresentation
        )
        guard expected.encoded == address,
              try BitcoinSilentPaymentAddress(address) == expected else {
            throw BitcoinSilentPaymentCryptoError.invalidKey
        }
        return self
    }

    var scanPublicKey: Data {
        (try? P256K.Signing.PrivateKey(
            dataRepresentation: scanPrivateKey
        ).publicKey.dataRepresentation) ?? Data()
    }

    var spendPublicKey: Data {
        (try? P256K.Signing.PrivateKey(
            dataRepresentation: spendPrivateKey
        ).publicKey.dataRepresentation) ?? Data()
    }
}

enum BitcoinSilentPaymentCrypto {
    private static let inputsTag = Data("BIP0352/Inputs".utf8)
    private static let sharedSecretTag = Data(
        "BIP0352/SharedSecret".utf8
    )
    private static let labelTag = Data("BIP0352/Label".utf8)
    private static let tapTweakTag = Data("TapTweak".utf8)

    static func taprootKeyPathPrivateKey(
        internalPrivateKey: Data
    ) throws -> Data {
        var internalKey = try P256K.Signing.PrivateKey(
            dataRepresentation: internalPrivateKey
        )
        if internalKey.publicKey.dataRepresentation.first == 0x03 {
            internalKey = internalKey.negation
        }
        let tweak = Data(SHA256.taggedHash(
            tag: tapTweakTag,
            data: Data(internalKey.publicKey.xonly.bytes)
        ))
        var outputKey = try internalKey.add(Array(tweak))
        if outputKey.publicKey.dataRepresentation.first == 0x03 {
            outputKey = outputKey.negation
        }
        return outputKey.dataRepresentation
    }

    static func destination(
        address: BitcoinSilentPaymentAddress,
        inputs: [BitcoinSilentPaymentInputSecret],
        outputCounter: UInt32 = 0
    ) throws -> BitcoinSilentPaymentDestination {
        guard !inputs.isEmpty else {
            throw BitcoinSilentPaymentCryptoError.noEligibleInputs
        }
        let sum = try summedPrivateKey(inputs)
        guard let smallestOutpoint = inputs.map(\.outpoint).min(by: {
            $0.lexicographicallyPrecedes($1)
        }) else {
            throw BitcoinSilentPaymentCryptoError.noEligibleInputs
        }
        let inputHash = Data(SHA256.taggedHash(
            tag: inputsTag,
            data: smallestOutpoint + sum.publicKey.dataRepresentation
        ))
        let tweaked = try sum.multiply(Array(inputHash))
        let ecdhPrivate = try P256K.KeyAgreement.PrivateKey(
            dataRepresentation: tweaked.dataRepresentation
        )
        let scanPublic = try P256K.KeyAgreement.PublicKey(
            dataRepresentation: address.scanPublicKey,
            format: .compressed
        )
        let sharedPoint = ecdhPrivate.sharedSecretFromKeyAgreement(
            with: scanPublic
        )
        let tweak = sharedSecretTweak(
            sharedPoint: Data(sharedPoint.bytes),
            outputCounter: outputCounter
        )
        let spendPublic = try P256K.Signing.PublicKey(
            dataRepresentation: address.spendPublicKey,
            format: .compressed
        )
        let destination = try spendPublic.add(Array(tweak))
        let outputKey = Data(destination.xonly.bytes)
        return BitcoinSilentPaymentDestination(
            outputPublicKey: outputKey,
            scriptPubKey: Data([0x51, 0x20]) + outputKey,
            sharedSecretTweak: tweak
        )
    }

    static func locateOutputs(
        keyMaterial: BitcoinSilentPaymentKeyMaterial,
        tweakPublicKey: Data,
        transactionOutputs: [Data]
    ) throws -> [BitcoinSilentPaymentOwnedOutputKey] {
        let material = try keyMaterial.validated()
        let tweakKey = try P256K.KeyAgreement.PublicKey(
            dataRepresentation: tweakPublicKey,
            format: .compressed
        )
        let scanKey = try P256K.KeyAgreement.PrivateKey(
            dataRepresentation: material.scanPrivateKey
        )
        let sharedPoint = scanKey.sharedSecretFromKeyAgreement(
            with: tweakKey
        )
        let spendPrivate = try P256K.Signing.PrivateKey(
            dataRepresentation: material.spendPrivateKey
        )
        let changeLabelTweak = labelTweak(
            scanPrivateKey: material.scanPrivateKey,
            label: 0
        )
        let candidates: [(UInt32?, P256K.Signing.PrivateKey)] = [
            (nil, spendPrivate),
            (0, try spendPrivate.add(Array(changeLabelTweak))),
        ]
        let indexedTaprootOutputs = transactionOutputs.enumerated()
            .compactMap { index, script -> (Int, Data)? in
                guard script.count == 34,
                      script.starts(with: [0x51, 0x20]) else {
                    return nil
                }
                return (index, Data(script.dropFirst(2)))
            }
        var remaining = Dictionary(
            uniqueKeysWithValues: indexedTaprootOutputs.map {
                ($0.0, $0.1)
            }
        )
        var found: [BitcoinSilentPaymentOwnedOutputKey] = []
        var counter: UInt32 = 0

        while counter < 2_323, !remaining.isEmpty {
            let tweak = sharedSecretTweak(
                sharedPoint: Data(sharedPoint.bytes),
                outputCounter: counter
            )
            var matched = false
            for (label, baseKey) in candidates {
                let outputPrivate = try baseKey.add(Array(tweak))
                let outputKey = Data(outputPrivate.publicKey.xonly.bytes)
                guard let match = remaining.first(where: {
                    $0.value == outputKey
                }) else { continue }
                let script = Data([0x51, 0x20]) + outputKey
                found.append(
                    BitcoinSilentPaymentOwnedOutputKey(
                        outputIndex: match.key,
                        outputPublicKey: outputKey,
                        scriptPubKey: script,
                        privateKey: outputPrivate.dataRepresentation,
                        label: label,
                        outputCounter: counter
                    )
                )
                remaining[match.key] = nil
                matched = true
                break
            }
            guard matched else { break }
            counter += 1
        }
        return found.sorted { $0.outputIndex < $1.outputIndex }
    }

    static func labelTweak(
        scanPrivateKey: Data,
        label: UInt32
    ) -> Data {
        Data(SHA256.taggedHash(
            tag: labelTag,
            data: scanPrivateKey + serializedUInt32(label)
        ))
    }

    private static func summedPrivateKey(
        _ inputs: [BitcoinSilentPaymentInputSecret]
    ) throws -> P256K.Signing.PrivateKey {
        var keys = try inputs.map { input in
            let key = try P256K.Signing.PrivateKey(
                dataRepresentation: input.privateKey
            )
            guard input.isTaproot,
                  key.publicKey.dataRepresentation.first == 0x03 else {
                return key
            }
            return key.negation
        }
        guard var sum = keys.first else {
            throw BitcoinSilentPaymentCryptoError.noEligibleInputs
        }
        keys.removeFirst()
        for key in keys {
            sum = try sum.add(Array(key.dataRepresentation))
        }
        return sum
    }

    private static func sharedSecretTweak(
        sharedPoint: Data,
        outputCounter: UInt32
    ) -> Data {
        Data(SHA256.taggedHash(
            tag: sharedSecretTag,
            data: sharedPoint + serializedUInt32(outputCounter)
        ))
    }

    private static func serializedUInt32(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}
