import BackgroundTasks
import UIKit
import OathAnkr
import OathBitcoin
import OathDatabase
import OathDiagnostics

/// Adding a send chain requires an exhaustive status adapter here. Send UI uses
/// this registry as a capability gate; journaling always queues tracking in SQL.
enum OathTrackedSendChain: String, CaseIterable {
    case bitcoin, bitcoincash, litecoin, dogecoin, sui, xrpl, stellar, tron, near, polkadot, aptos, thorchain, ton, solana, arc

    case ethereum, arbitrum, avalanche, base, bnb, fantom, flare, somnia, story, gnosis, linea, optimism, polygon, chiliz, filecoin, sei, zerog, iotex, celo, monad, unichain, hyperevm, robinhood, scroll, taiko, telos, xlayer

    static func check(_ send: SendRecord, database: OathDatabase) async throws {
        if send.state == "confirmed",let removal=try await database.permissionRemoval(sendID:send.id),removal.status=="pending" {
            try await OathPermissionService.shared.recheck(removal,database:database);return
        }
        guard let chain = Self(rawValue: send.networkID) else { throw StoreError.invalidValue("missing send status adapter") }
        switch chain {
        case .bitcoin, .bitcoincash, .litecoin, .dogecoin:
            guard let network = UTXONetwork(rawValue: chain.rawValue) else { throw BitcoinError.wrongNetwork }
            try await OathBitcoinSendService.service(for: network).check(send: send, database: database)
        case .sui: try await OathSuiSendService.shared.check(send: send, database: database)
        case .xrpl: try await OathXrplSendService.shared.check(send: send, database: database)
        case .stellar: try await OathStellarSendService.shared.check(send: send, database: database)
        case .tron: try await OathTronSendService.shared.check(send: send, database: database)
        case .ton: try await OathTonSendService.shared.check(send: send, database: database)
        case .solana: try await OathSolanaSendService.shared.check(send:send,database:database)
        case .ethereum, .arbitrum, .avalanche, .base, .bnb, .fantom, .flare, .somnia, .story, .gnosis, .linea, .optimism, .polygon, .chiliz, .filecoin, .sei, .zerog, .iotex, .celo, .monad, .unichain, .hyperevm, .robinhood, .scroll, .taiko, .telos, .xlayer:
            try await OathEVMSendService.shared.check(send:send,database:database)
        case .arc:
            if try await database.evmSendPlan(sendID: send.id) != nil {
                try await OathEVMSendService.shared.check(send: send, database: database)
            } else { try await OathArcSendService.shared.check(send:send,database:database) }
        case .thorchain: try await OathThorchainSendService.shared.check(send: send, database: database)
        case .aptos: try await OathAptosSendService.shared.check(send: send, database: database)
        case .polkadot: try await OathPolkadotSendService.shared.check(send: send, database: database)
        case .near: try await OathNearSendService.shared.check(send: send, database: database)
        }
    }
}

/// Main actor owns only UIKit lifecycle tokens. All SQL, cryptography and RPC
/// reconciliation run on the worker/services' actors, independently of screens,
/// selection and vault unlock. iOS decides when suspended apps can execute.
@MainActor final class OathSendStatusTracking {
    static let shared = OathSendStatusTracking()
    static let taskID = "org.oathwallet.send-status"
    private let launchedAt = Date.now.timeIntervalSince1970
    private var opening: Task<SendStatusTracker, Error>?
    private var foreground = false
    private var resetting = false
    private var observers: [NSObjectProtocol] = []
    private var activation: Task<Void, Never>?
    private var window: Task<Void, Never>?
    private var windowID = UUID()
    private var backgroundTask: BGAppRefreshTask?
    private var assertion: UIBackgroundTaskIdentifier = .invalid

    func register() {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskID, using: .main) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in self.runWindow(task) }
        }
        if !registered {
            OathDiagnostics.record(StoreError.invalidValue("background registration"), component: "send", operation: "status_background_register")
        }
        for (name, active) in [(UIApplication.didBecomeActiveNotification, true), (UIApplication.didEnterBackgroundNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in self.setForeground(active) }
            })
        }
        if UIApplication.shared.applicationState != .background { setForeground(true) }
    }

    private func worker() async throws -> SendStatusTracker {
        if let opening { return try await opening.value }
        let cutoff = launchedAt
        let task = Task {
            let database = try await OathDataEnvironment.shared.database()
            try await database.cancelAbandonedUnsignedSends(before: cutoff)
            return SendStatusTracker(database: database) { send in
                try await OathTrackedSendChain.check(send, database: database)
            }
        }
        opening = task
        do { return try await task.value }
        catch {
            OathDiagnostics.record(error, component: "send", operation: "status_open")
            opening = nil; throw error
        }
    }

    private func setForeground(_ value: Bool) {
        foreground = value
        activation?.cancel(); activation = nil
        if value {
            finishWindow(success: true)
            activation = Task {
                while foreground, !resetting, !Task.isCancelled {
                    do {
                        let worker = try await worker()
                        guard foreground, !resetting, !Task.isCancelled else { return }
                        await worker.resume()
                        return
                    } catch {
                        if Task.isCancelled { return }
                        OathDiagnostics.record(error, component: "send", operation: "status_start")
                        // A transient protected-data/SQL failure must not disable
                        // tracking for the rest of this foreground session.
                        do { try await Task.sleep(for: .seconds(15)) }
                        catch { return } // Lifecycle cancellation.
                    }
                }
            }
        } else { runWindow(nil) }
    }

    private func runWindow(_ task: BGAppRefreshTask?) {
        guard !resetting else { task?.setTaskCompleted(success: false); return }
        finishWindow(success: true, stopWorker: false)
        let token = UUID(); windowID = token; backgroundTask = task
        if let task {
            task.expirationHandler = { Task { @MainActor in self.finishWindow(token: token, success: false) } }
        } else {
            assertion = UIApplication.shared.beginBackgroundTask(withName: "Send status") {
                // UIKit's expiration handler is already on MainActor. End the
                // assertion synchronously, before iOS suspends the process.
                self.finishWindow(token: token, success: false)
            }
        }
        window = Task {
            do {
                let worker = try await worker()
                guard windowID == token, !Task.isCancelled, !resetting else { return }
                await worker.resume()
                await scheduleBackground()
                try await Task.sleep(for: .seconds(20))
                finishWindow(token: token, success: true)
            } catch is CancellationError { /* Lifecycle window ended. */ }
            catch {
                OathDiagnostics.record(error, component: "send", operation: "status_background")
                finishWindow(token: token, success: false)
            }
        }
    }

    private func finishWindow(token: UUID? = nil, success: Bool, stopWorker: Bool = true) {
        if let token, token != windowID { return }
        windowID = UUID(); window?.cancel(); window = nil
        backgroundTask?.setTaskCompleted(success: success); backgroundTask = nil
        if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion); assertion = .invalid }
        if stopWorker && (!foreground || resetting) {
            let ended = windowID
            Task {
                guard windowID == ended, !foreground || resetting else { return }
                if let opening, let worker = await OathDiagnostics.attempt("status_pause_worker", body: { try await opening.value }) {
                    guard windowID == ended, !foreground || resetting else { return }
                    await worker.pause()
                    if (foreground || window != nil), !resetting { await worker.resume() }
                }
                await scheduleBackground()
            }
        }
    }

    private func scheduleBackground() async {
        guard !resetting else { return }
        do {
            let db = try await OathDataEnvironment.shared.database()
            guard try await db.nextSendStatusDeadline() != nil else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID); return
            }
            // earliestBeginDate is a request, never a promise of exact execution.
            let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // User/system-disabled background refresh is expected. Foreground
            // recovery remains active and all unfinished jobs remain on disk.
            if (error as? BGTaskScheduler.Error)?.code == .unavailable { return }
            OathDiagnostics.record(error, component: "send", operation: "status_background_schedule")
        }
    }

    func beginReset() async {
        resetting = true; activation?.cancel(); activation = nil; finishWindow(success: false)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
        if let opening, let worker = await OathDiagnostics.attempt("status_reset_worker", body: { try await opening.value }) { await worker.pause() }
    }
    func endReset() { resetting = false; if foreground { setForeground(true) } }
}
