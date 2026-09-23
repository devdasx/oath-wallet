import Foundation
import Testing
@testable import Aperture

struct SolanaSyncCoordinatorTests {
    private final class DatabaseIdentity: Sendable {}

    @Test
    func overlappingScreensShareWorkAndCancellationIsPerSubscriber() async {
        let coordinator = SolanaSyncCoordinator()
        let database = DatabaseIdentity()
        let key = SolanaSyncCoordinator.Key(databaseID: ObjectIdentifier(database), walletID: "wallet")
        let events = SolanaSyncTestEvents()
        let operation: SolanaSyncCoordinator.Operation = { progress in
            await events.mark("read")
            await progress(.init(source: .solana, stage: .balancesPersisted))
            await events.wait("release")
            await events.mark("write")
            return .success(.solana)
        }
        let first = Task {
            await coordinator.sync(key: key, onProgress: { _ in await events.mark("first-progress") }, operation: operation)
        }
        await events.wait("first-progress")
        let second = Task {
            await coordinator.sync(key: key, onProgress: { _ in await events.mark("second-progress") }, operation: operation)
        }
        await events.wait("second-progress")
        first.cancel()
        #expect(await first.value == .cancelled(.solana))
        await events.mark("release")
        #expect(await second.value == .success(.solana))
        #expect(await events.count("read") == 1)
        #expect(await events.count("write") == 1)

        // A later refresh performs real work; there is no time-based balance cache.
        #expect(await coordinator.sync(key: key, operation: operation) == .success(.solana))
        #expect(await events.count("read") == 2)
    }

    @Test
    func postSendDrainsAnUncancellableOldWriteBeforeStartingFreshReads() async {
        let coordinator = SolanaSyncCoordinator()
        let database = DatabaseIdentity()
        let key = SolanaSyncCoordinator.Key(databaseID: ObjectIdentifier(database), walletID: "wallet")
        let events = SolanaSyncTestEvents()
        let old = Task {
            await coordinator.sync(key: key) { _ in
                await events.mark("old-read")
                await withTaskCancellationHandler {
                    // Models a database write already submitted to another queue.
                    await events.wait("old-write-release")
                    await events.mark("old-write")
                } onCancel: {
                    Task { await events.mark("old-cancelled") }
                }
                return .success(.solana)
            }
        }
        await events.wait("old-read")
        let fresh = Task {
            await coordinator.sync(key: key, requiresFresh: true) { _ in
                await events.mark("fresh-read")
                await events.mark("fresh-write")
                return .success(.solana)
            }
        }
        await events.wait("old-cancelled")
        #expect(await events.count("fresh-read") == 0)
        await events.mark("old-write-release")
        _ = await old.value
        #expect(await fresh.value == .success(.solana))
        let sequence = await events.sequence()
        #expect(sequence.firstIndex(of: "old-write")! < sequence.firstIndex(of: "fresh-read")!)
        #expect(sequence.firstIndex(of: "fresh-read")! < sequence.firstIndex(of: "fresh-write")!)
    }

    @Test
    func walletsAndDatabaseInstancesNeverShareResults() async {
        let coordinator = SolanaSyncCoordinator()
        let firstDatabase = DatabaseIdentity()
        let secondDatabase = DatabaseIdentity()
        let keys = [
            SolanaSyncCoordinator.Key(databaseID: ObjectIdentifier(firstDatabase), walletID: "first"),
            SolanaSyncCoordinator.Key(databaseID: ObjectIdentifier(firstDatabase), walletID: "second"),
            SolanaSyncCoordinator.Key(databaseID: ObjectIdentifier(secondDatabase), walletID: "first")
        ]
        let events = SolanaSyncTestEvents()
        await withTaskGroup(of: WalletChainSyncOutcome.self) { group in
            for (index, key) in keys.enumerated() {
                group.addTask {
                    await coordinator.sync(key: key) { _ in
                        await events.mark("read-\(index)")
                        await events.wait("release")
                        return .success(.solana)
                    }
                }
            }
            for index in keys.indices { await events.wait("read-\(index)") }
            await events.mark("release")
            for await result in group { #expect(result == .success(.solana)) }
        }
    }

    @Test
    func lastSubscriberCancellationStopsUnderlyingWork() async {
        let coordinator = SolanaSyncCoordinator()
        let database = DatabaseIdentity()
        let key = SolanaSyncCoordinator.Key(databaseID: ObjectIdentifier(database), walletID: "wallet")
        let events = SolanaSyncTestEvents()
        let task = Task {
            await coordinator.sync(key: key) { _ in
                await withTaskCancellationHandler {
                    await events.mark("started")
                    await events.wait("cancelled")
                } onCancel: {
                    Task { await events.mark("cancelled") }
                }
                #expect(Task.isCancelled)
                return .cancelled(.solana)
            }
        }
        await events.wait("started")
        task.cancel()
        #expect(await task.value == .cancelled(.solana))
        await events.wait("cancelled")
    }
}

private actor SolanaSyncTestEvents {
    private var events: [String] = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func mark(_ event: String) {
        events.append(event)
        for waiter in waiters.removeValue(forKey: event) ?? [] { waiter.resume() }
    }

    func wait(_ event: String) async {
        if events.contains(event) { return }
        await withCheckedContinuation { waiters[event, default: []].append($0) }
    }

    func count(_ event: String) -> Int { events.filter { $0 == event }.count }
    func sequence() -> [String] { events }
}
