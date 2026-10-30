import Foundation

/// Keychain IPC runs on a dedicated serial executor, not a cooperative task
/// worker. No owner, arbitrary Encodable, or mutable payload crosses a GCD hop.
actor QueuedSerializer {
    private final class Executor: SerialExecutor {
        let queue = DispatchQueue(label: "com.walletconnect.networking.serialization", qos: .userInitiated)
        func enqueue(_ job: UnownedJob) {
            queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
        }
    }
    private nonisolated let executor = Executor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let serializer: Serializing

    init(serializer: Serializing) { self.serializer = serializer }

    func serialize(topic: String?, json: String, envelopeType: Envelope.EnvelopeType) throws -> String {
        try Task.checkCancellation()
        return try serializer.serialize(topic: topic, json: json, envelopeType: envelopeType, codingType: .base64Encoded)
    }
}
