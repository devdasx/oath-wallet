import Foundation
import SwiftUI

struct AppRootWalletContextReadinessRequest: @unchecked Sendable {
    let requestID: UUID
    let gate = AppRootWalletContextReadinessGate()
}

final class AppRootWalletContextReadinessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func resolve(_ result: Bool) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()

        for waiter in pending {
            waiter.resume(returning: result)
        }
    }
}

enum WalletSwitcherNavigationRoute: Hashable, Sendable {
    case settings(walletID: String)
    case setup(WalletSwitcherSetupRoute)
}

enum WalletSwitcherSheetDetentPolicy {
    static let allowedDetents: Set<PresentationDetent> = [.large]
}

extension AppRootView {
    @MainActor
    func presentWalletSwitcher() {
        guard phase == .wallet, !isWalletSwitcherPresented else {
            return
        }
        isWalletSwitcherPresented = true
    }

    @MainActor
    func completeHomeWalletAdd(_ address: String) async -> Bool {
        PushNotificationCoordinator.shared.walletDataDidChange()
        let requestID = loadWalletAddress(address)
        return await awaitWalletContextReadiness(
            requestID: requestID
        )
    }

    @MainActor
    func awaitWalletContextReadiness(requestID: UUID) async -> Bool {
        if walletPresentation.requestID == requestID,
           walletPresentation.resolvedContext != nil {
            return true
        }
        guard let readiness = walletContextReadinessRequest,
              readiness.requestID == requestID else {
            return false
        }
        let isReady = await readiness.gate.wait()
        return isReady && !Task.isCancelled
    }

    @MainActor
    func walletSwitcherDidDismiss() {
        let startsDestructiveFlow =
            destructiveFlow.sourceDidDismiss(.walletSwitcher)
        walletSwitcherNavigationPath.removeAll(keepingCapacity: false)
        coveringModalDidDismiss(.homeWalletSwitcher)
        if !startsDestructiveFlow {
            destructiveFlow.sourceRestorationDidEnd(.walletSwitcher)
        }
    }

    @MainActor
    func homeWalletAddDidDismiss() {
        coveringModalDidDismiss(.homeWalletAdd)
    }

    @ViewBuilder
    func walletSwitcherSettingsDestination(
        walletID: String
    ) -> some View {
        WalletSwitcherSettingsView(
            database: database,
            walletID: walletID,
            onWalletSelected: { address in
                walletSwitcherContentDidChange()
                loadWalletAddress(address)
            },
            onWalletRenamed: { address, name in
                PushNotificationCoordinator.shared
                    .walletDataDidChange()
                updateCurrentWalletName(
                    address: address,
                    name: name
                )
                walletSwitcherContentDidChange()
            },
            onWalletAppearanceChanged: { walletID, color in
                updateCurrentWalletAppearanceColor(
                    walletID: walletID,
                    color: color
                )
            },
            onWalletChanged: {
                walletSwitcherContentDidChange()
            },
            onRemoveWalletRequested:
                requestWalletSwitcherWalletRemoval
        )
    }

    @MainActor
    func walletSwitcherContentDidChange() {
        walletSwitcherRefreshGeneration = UUID()
    }
}
