import Foundation
import Combine

public class Serializer: Serializing {

    public enum Errors: Error, CustomStringConvertible {
        case symmetricKeyForTopicNotFound(String)
        case publicKeyForTopicNotFound
        case invalidType2Envelope
        case topicNotFound

        public var description: String {
            switch self {
            case .symmetricKeyForTopicNotFound(let topic):
                return "Error: Symmetric key for topic '\(topic)' was not found."
            case .publicKeyForTopicNotFound:
                return "Error: Public key for topic was not found."
            case .invalidType2Envelope:
                return "Error: Invalid type 2 envelope."
            case .topicNotFound:
                return "Error: Topic not found."
            }
        }
    }

    private let kms: KeyManagementServiceProtocol
    private let codec: Codec
    public let logger: ConsoleLogging
    public var logsPublisher: AnyPublisher<Log, Never> {
        logger.logsPublisher.eraseToAnyPublisher()
    }

    init(kms: KeyManagementServiceProtocol, codec: Codec = ChaChaPolyCodec(), logger: ConsoleLogging) {
        self.kms = kms
        self.codec = codec
        self.logger = logger
    }

    public init(kms: KeyManagementServiceProtocol, logger: ConsoleLogging) {
        self.kms = kms
        self.codec = ChaChaPolyCodec()
        self.logger = logger
    }

    public func setLogging(level: LoggingLevel) {
        logger.setLogging(level: level)
    }

    /// Encrypts and serializes an object
    /// - Parameters:
    ///   - topic: Topic that is associated with a symetric key for encrypting particular codable object
    ///   - encodable: Object to encrypt and serialize
    ///   - envelopeType: type of envelope
    /// - Returns: Serialized String
    public func serialize(topic: String?, encodable: Encodable, envelopeType: Envelope.EnvelopeType, codingType: Envelope.CodingType) throws -> String {
        let json = envelopeType == .type2 ? try encodable.asJSONEncodedString() : try encodable.json()
        return try serialize(topic: topic, json: json, envelopeType: envelopeType, codingType: codingType)
    }

    public func serialize(topic: String?, json: String, envelopeType: Envelope.EnvelopeType, codingType: Envelope.CodingType) throws -> String {
        if envelopeType == .type2 {
            return Envelope(type: .type2, sealbox: Data(json.utf8), codingType: codingType).serialised(codingType: codingType)
        }
        guard let topic = topic else {
            let error = Errors.topicNotFound
            logger.error("\(error)")
            throw error
        }
        guard let symmetricKey = kms.getSymmetricKeyRepresentable(for: topic) else {
            let error = Errors.symmetricKeyForTopicNotFound(topic)
            logger.error("\(error)")
            throw error
        }
        let sealbox = try codec.encode(plaintext: json, symmetricKey: symmetricKey)
        return Envelope(type: envelopeType, sealbox: sealbox, codingType: codingType).serialised(codingType: codingType)
    }

    /// Deserializes and decrypts an object
    /// - Parameters:
    ///   - topic: Topic that is associated with a symetric key for decrypting particular codable object
    ///   - encodedEnvelope: Envelope to deserialize and decrypt
    /// - Returns: Deserialized object
    public func deserialize<T: Codable>(topic: String, codingType: Envelope.CodingType, envelopeString: String) throws -> (T, derivedTopic: String?, decryptedPayload: Data) {
        let envelope = try Envelope(codingType, envelopeString: envelopeString)
        switch envelope.type {
        case .type0:
            let deserialisedType: (object: T, data: Data) = try handleType0Envelope(topic, envelope)
            return (deserialisedType.object, nil, deserialisedType.data)
        case .type1(let peerPubKey):
            return try handleType1Envelope(topic, peerPubKey: peerPubKey, sealbox: envelope.sealbox)
        case .type2:
            let decodedType: T = try handleType2Envelope(envelope: envelope)
            return (decodedType, nil, Data())
        }
    }

    private func handleType0Envelope<T: Codable>(_ topic: String, _ envelope: Envelope) throws -> (T, Data) {
        if let symmetricKey = kms.getSymmetricKeyRepresentable(for: topic) {
            do {
                let decoded: (T, Data) = try decode(sealbox: envelope.sealbox, symmetricKey: symmetricKey)
                logger.debug("Decoded: \(decoded.0)")
                return decoded
            }
            catch {
                logger.debug("\(error)")
                throw error
            }
        } else {
            let error = Errors.symmetricKeyForTopicNotFound(topic)
            logger.error("\(error)")
            throw error
        }
    }

    private func handleType1Envelope<T: Codable>(_ topic: String, peerPubKey: Data, sealbox: Data) throws -> (T, String, Data) {
        guard let selfPubKey = kms.getPublicKey(for: topic)
        else {
            let error = Errors.publicKeyForTopicNotFound
            logger.error("\(error)")
            throw error
        }

        let agreementKeys = try kms.performKeyAgreement(selfPublicKey: selfPubKey, peerPublicKey: peerPubKey.toHexString())
        let decodedType: (object: T, data: Data) = try decode(sealbox: sealbox, symmetricKey: agreementKeys.sharedKey.rawRepresentation)
        let derivedTopic = agreementKeys.derivedTopic()
        try kms.setAgreementSecret(agreementKeys, topic: derivedTopic)
        return (decodedType.object, derivedTopic, decodedType.data)
    }

    private func handleType2Envelope<T: Codable>(envelope: Envelope) throws -> T {
        do {
            let deserialised = try JSONDecoder().decode(T.self, from: envelope.sealbox)
            return deserialised
        } catch {
            logger.error(error)
            throw error
        }
    }

    private func decode<T: Codable>(sealbox: Data, symmetricKey: Data) throws -> (T, Data) {
        var decryptedData = Data()
        print(T.self)
        do {
            decryptedData = try codec.decode(sealbox: sealbox, symmetricKey: symmetricKey)
            let decodedType = try JSONDecoder().decode(T.self, from: decryptedData)
            return (decodedType, decryptedData)
        } catch {
            let str = String(decoding: decryptedData, as: UTF8.self)
            logger.debug(str)
            throw error
        }
    }
}
