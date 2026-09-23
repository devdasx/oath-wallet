import BackgroundTasks
import Foundation
import Testing
@testable import Aperture

@MainActor
struct WalletPrivateDiscoveryBackgroundTasksTests {
    @Test func launchDeliveryUsesMainQueueAndRegistersOnlyOnce() async throws {
        var registeredQueue: DispatchQueue?
        var registrationCount = 0
        let scheduler = WalletPrivateDiscoveryBackgroundTasks { identifier, queue, _ in
            #expect(identifier == WalletPrivateDiscoveryBackgroundTasks.taskIdentifier)
            registeredQueue = queue
            registrationCount += 1
            return true
        }

        scheduler.register()
        scheduler.register()
        #expect(registrationCount == 1)

        // nil means the OS's private background queue, which caused the device
        // crash before the MainActor-isolated launch callback could execute.
        let queue = try #require(registeredQueue)
        #expect(queue === DispatchQueue.main)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                queue.async {
                    #expect(Thread.isMainThread)
                    continuation.resume()
                }
            }
        }
    }

    @Test func unsuccessfulRegistrationCanBeRetried() {
        var attempts = 0
        let scheduler = WalletPrivateDiscoveryBackgroundTasks { _, queue, _ in
            #expect(queue === DispatchQueue.main)
            attempts += 1
            return attempts == 2
        }
        scheduler.register()
        scheduler.register()
        scheduler.register()
        #expect(attempts == 2)
    }

    @Test(arguments: [false, true])
    func expirationEntersFromEitherQueueAndUpdatesOnMainActor(
        backgroundDelivery: Bool
    ) async {
        var expirationCount = 0
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let handler = WalletPrivateDiscoveryBackgroundTasks.makeExpirationHandler {
                MainActor.assertIsolated()
                #expect(Thread.isMainThread)
                expirationCount += 1
                continuation.resume()
            }
            let queue = backgroundDelivery ? DispatchQueue.global() : DispatchQueue.main
            queue.async {
                #expect(Thread.isMainThread == !backgroundDelivery)
                handler()
            }
        }
        #expect(expirationCount == 1)
    }
}
