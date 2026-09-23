import SwiftUI
import UIKit
import GRDB
import Testing
@testable import Aperture

struct AppRootDestinationAppearanceTests {
    @Test
    func launchDestinationUsesFadeAndSubtlePop() {
        let style = AppRootDestinationAppearanceStyle.resolved(
            reduceMotion: false
        )

        #expect(style.initialOpacity == 0)
        #expect(style.initialScale == 0.985)
        #expect(style.duration == 0.30)
    }

    @Test
    func reducedMotionLaunchDestinationDoesNotScale() {
        let style = AppRootDestinationAppearanceStyle.resolved(
            reduceMotion: true
        )

        #expect(style.initialOpacity == 0)
        #expect(style.initialScale == 1)
        #expect(style.duration == 0.18)
    }
}

@MainActor
@Suite(.serialized)
struct AppResetNavigationTests {
    @Test(arguments: [false, true], [NativeListTestLayout.phone, .largeTextRTL])
    func completedResetDismissesEveryPresentationAndRendersOnboarding(
        databaseIsBusy: Bool, layout: NativeListTestLayout
    ) async throws {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ResetNavigationTest-" + UUID().uuidString)
        let database = try WalletDatabase.applicationDatabase(at: directory)
        defer { try? database.pool.close() }
        try await seedWallet(database)
        let settings = WalletSettingsStore(database: database)
        let language = layout.direction == .rightToLeft ? "ar" : "en"
        settings.setLanguageIdentifier(language)
        #expect(await settings.flush())
        let probe = ResetRootProbe()
        let resetActions = AppResetTestActions()
        var root = AppRootView(database: database)
        root.testObserver = {
            probe.root = $0
            probe.phases.append($0.phase)
        }
        let host = try NativeListTestHost(layout: layout) {
            root
                .environment(settings)
                .environment(PushNotificationCoordinator.shared)
                .environment(WalletAppDeepLinkCoordinator())
                .environment(\.scenePhase, .active)
                .environment(\.appResetTestActions, resetActions)
        }
        defer {
            resetActions.begin = nil
            resetActions.complete = nil
            probe.root = nil
            host.close()
        }
        try await wait(host) { probe.root?.phase == .wallet }
        probe.root?.requestResetAppDataFlow()
        try await wait(host) { resetActions.begin != nil }
        resetActions.begin?()
        try await wait(host, seconds: 60) { resetActions.complete != nil }
        #expect(try await database.managedWalletCount() == 0)
        // Occupy the real GRDB reader pool to reproduce a delayed launch lookup.
        // Onboarding after a committed reset must not depend on another read.
        let readers = ResetReaderBarrier()
        let tasks = (0..<(databaseIsBusy ? 4 : 0)).map { _ in
            Task.detached {
                try await database.pool.read { db in
                    _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM wallets")
                    readers.enterAndWait()
                }
            }
        }
        defer {
            readers.release()
            tasks.forEach { $0.cancel() }
        }
        try await wait(host) { readers.count == (databaseIsBusy ? 4 : 0) }
        probe.phases.removeAll()
        resetActions.complete?()
        try await wait(host, seconds: 15) {
            probe.root?.phase == .onboarding && presentedController(host) == nil
        }
        try await wait(host) { renderedBlueFraction(host) > 0.02 }
        #expect(probe.root?.phase == .onboarding)
        #expect(presentedController(host) == nil)
        #expect(!probe.phases.contains(.startup))
        #expect(probe.root?.isWalletLocked == false)
        #expect(settings.languageIdentifier == language)
        saveScreenshot(host, name: "reset-navigation-passed.png")
        readers.release()
        for task in tasks { _ = try? await task.value }
    }

    private func renderedBlueFraction(_ host: NativeListTestHost) -> Double {
        guard let window = host.rootView.window else { return 0 }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage else { return 0 }
        let width = 100, height = 200
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let blue = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            var count = 0
            for pixel in stride(from: 0, to: buffer.count, by: 4) {
                if buffer[pixel] < 60 && buffer[pixel + 1] > 80 && buffer[pixel + 1] < 210
                    && buffer[pixel + 2] > 210 { count += 1 }
            }
            return count
        }
        return Double(blue) / Double(width * height)
    }

    private func wait(
        _ host: NativeListTestHost, seconds: Int = 10,
        sourceLocation: SourceLocation = #_sourceLocation, until condition: () -> Bool
    ) async throws {
        for _ in 0..<(seconds * 20) {
            await Task.yield()
            host.rootView.window?.layoutIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        saveScreenshot(host, name: "reset-navigation-failure.png")
        try #require(condition(), "The real reset-to-onboarding transition did not settle", sourceLocation: sourceLocation)
    }

    private func saveScreenshot(_ host: NativeListTestHost, name: String) {
        if let window = host.rootView.window {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            if let data = image.pngData() {
                try? data.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent(name))
            }
        }
    }

    private func presentedController(_ host: NativeListTestHost) -> UIViewController? {
        host.rootView.window?.rootViewController?.presentedViewController
    }

    private func seedWallet(_ database: WalletDatabase) async throws {
        try await database.pool.write { db in
            let now = Date().timeIntervalSince1970
            try DBWalletRecord(
                id: "reset-ui-wallet", profileID: WalletDatabase.defaultProfileID,
                name: "Reset UI Fixture", kind: DatabaseWalletKind.watchOnly.rawValue,
                secretKeyReference: nil, isSelected: true, sortOrder: 0,
                createdAt: now, updatedAt: now, lastOpenedAt: now, archivedAt: nil
            ).insert(db)
            try DBWalletAccountRecord(
                id: "reset-ui-account", walletID: "reset-ui-wallet", networkID: "eth",
                address: "0x1111111111111111111111111111111111111111",
                normalizedAddress: "0x1111111111111111111111111111111111111111",
                label: nil, derivationPath: nil, accountIndex: 0, publicKey: "public",
                isWatchOnly: true, isEnabled: true, createdAt: now, updatedAt: now,
                lastSyncedAt: nil
            ).insert(db)
        }
    }
}

@MainActor
private final class ResetRootProbe {
    var root: AppRootView?
    var phases: [AppRootPhase] = []
}

private final class ResetReaderBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = 0
    private var released = false
    var count: Int { lock.withLock { entered } }
    func enterAndWait() {
        lock.withLock { entered += 1 }
        semaphore.wait()
    }
    func release() {
        let shouldRelease = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        if shouldRelease { for _ in 0..<4 { semaphore.signal() } }
    }
}
