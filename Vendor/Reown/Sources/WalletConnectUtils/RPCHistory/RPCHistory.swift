import Foundation
import CryptoKit

public protocol RPCHistoryProtocol {
    
    func deleteAll(forTopic topic: String)
    
    func deleteAll(forTopics topics: [String])
}

public final class RPCHistory: RPCHistoryProtocol {

    public struct Record: Codable {
        public enum Origin: String, Codable {
            case local
            case remote
        }
        public enum TransportType: Codable {
            case relay
            case linkMode
        }
        public let id: RPCID
        public let topic: String
        public let expectedResponseTopic: String?
        public let origin: Origin
        public let request: RPCRequest
        public let response: RPCResponse?
        public var timestamp: Date?
        public let transportType: TransportType?

        fileprivate var responseTopic: String? {
            if let expectedResponseTopic { return expectedResponseTopic }
            // Preserve authentication requests persisted before explicit routing
            // metadata existed. The protocol response topic is SHA256(requester
            // public key), not the pairing topic. Never accept an arbitrary topic.
            if request.method == "wc_sessionAuthenticate" {
                guard let routing = try? request.params?.get(AuthenticationRouting.self),
                      routing.requester.publicKey.utf8.count == 64,
                      routing.requester.publicKey.utf8.allSatisfy({
                          (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                      }) else { return nil }
                return Data(SHA256.hash(data: Data(hex: routing.requester.publicKey))).toHexString()
            }
            return topic
        }

        private struct AuthenticationRouting: Codable {
            struct Requester: Codable { let publicKey: String }
            let requester: Requester
        }
    }

    enum HistoryError: Error, LocalizedError {
        case unidentifiedRequest
        case unidentifiedResponse
        case requestDuplicateNotAllowed
        case responseDuplicateNotAllowed
        case requestMatchingResponseNotFound
        case responseTopicMismatch
        var errorDescription: String? {
            switch self {
            case .unidentifiedRequest:
                return "Unidentified request."
            case .unidentifiedResponse:
                return "Unidentified response."
            case .requestDuplicateNotAllowed:
                return "Request duplicates are not allowed."
            case .responseDuplicateNotAllowed:
                return "Response duplicates are not allowed."
            case .requestMatchingResponseNotFound:
                return "Matching request for the response not found."
            case .responseTopicMismatch:
                return "Response does not match the pending request topic."
            }
        }
    }


    // Networking, pairing and signing create separate histories over the same
    // persisted namespace. Serialize complete local operations across instances,
    // not just individual storage calls. No network await runs under this lock.
    private static let storageLock = NSRecursiveLock()

    private let storage: CodableStore<Record>

    init(keyValueStore: CodableStore<Record>) {
        self.storage = keyValueStore

        removeOutdated()
    }

    public func get(recordId: RPCID) -> Record? {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        return try? storage.get(key: recordId.string)
    }

    public func set(_ request: RPCRequest, forTopic topic: String, emmitedBy origin: Record.Origin, time: TimeProvider = DefaultTimeProvider(), transportType: RPCHistory.Record.TransportType) throws {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        guard let id = request.id else {
            throw HistoryError.unidentifiedRequest
        }
        guard get(recordId: id) == nil else {
            throw HistoryError.requestDuplicateNotAllowed
        }
        let record = Record(id: id, topic: topic, expectedResponseTopic: request.expectedResponseTopic, origin: origin, request: request, response: nil, timestamp: time.currentDate, transportType: transportType)
        storage.set(record, forKey: "\(record.id)")
    }

    @discardableResult
    public func resolve(_ response: RPCResponse, forResponseTopic topic: String? = nil) throws -> Record {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        let record = try validate(response)
        if let topic {
            guard record.origin == .local,
                  record.responseTopic == topic else {
                throw HistoryError.responseTopicMismatch
            }
        }
        storage.delete(forKey: "\(record.id)")
        return record
    }

    @discardableResult
    public func validate(_ response: RPCResponse) throws -> Record {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        guard let id = response.id else {
            throw HistoryError.unidentifiedResponse
        }
        guard let record = get(recordId: id) else {
            throw HistoryError.requestMatchingResponseNotFound
        }
        guard record.response == nil else {
            throw HistoryError.responseDuplicateNotAllowed
        }
        return record
    }

    public func deleteAll(forTopics topics: [String]){
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        storage.getAll().forEach { record in
            if topics.contains(record.topic) {
                storage.delete(forKey: "\(record.id)")
            }
        }
    }

    public func getAll<Object: Codable>(of type: Object.Type, topic: String) -> [Object] {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        return storage.getAll()
            .filter{$0.topic == topic}
            .compactMap { try? $0.request.params?.get(Object.self) }
    }

    public func getAll<Object: Codable>(of type: Object.Type) -> [Object] {
        return getAllWithIDs(of: type).map { $0.value }
    }

    public func getAllWithIDs<Object: Codable>(of type: Object.Type) -> [(id: RPCID, value: Object)] {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        return storage.getAll().compactMap { record in
            guard let object = try? record.request.params?.get(Object.self)
            else { return nil }
            return (record.id, object)
        }
    }

    public func delete(id: RPCID) {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        storage.delete(forKey: id.string)
    }

    public func deleteAll(forTopic topic: String) {
        deleteAll(forTopics: [topic])
    }

    public func getPending() -> [Record] {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        return storage.getAll().filter { $0.response == nil }
    }

    public func deleteAll() {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        storage.deleteAll()
    }
}

extension RPCHistory {

    func removeOutdated() {
        Self.storageLock.lock()
        defer { Self.storageLock.unlock() }
        let records = storage.getAll()

        let thirtyDays: TimeInterval = 30*86400

        for var record in records {
            if let timestamp = record.timestamp {
                if timestamp.distance(to: Date()) > thirtyDays {
                    storage.delete(forKey: record.id.string)
                }
            } else {
                record.timestamp = Date()
                storage.set(record, forKey: "\(record.id)")
            }
        }
    }
}

#if DEBUG
class MockRPCHistory: RPCHistoryProtocol {
    var deletedTopics: [String] = []
    
    func deleteAll(forTopic topic: String) {
        deletedTopics.append(topic)
    }

    func deleteAll(forTopics topics: [String]) {
        deletedTopics.append(contentsOf: topics)
    }
}
#endif
