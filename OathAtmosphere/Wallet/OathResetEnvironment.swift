import Foundation

/// Injectable so reset/failure recovery is exercised with synthetic stores,
/// without touching a developer's Keychain, cloud account or app container.
protocol OathResetEnvironment: Sendable {
    func suspend() async
    func eraseLocalFiles() async throws
    func reopen() async
    func discardTestWalletConnections() async
}

extension OathResetEnvironment {
    func discardTestWalletConnections() async { }
}

struct OathLocalResetEnvironment: OathResetEnvironment {
    func suspend() async {
        await OathCloudBackupService.shared.suspendForReset()
        #if canImport(UIKit)
        await OathSensitiveClipboard.clearIfOwned()
        #endif
    }
    func reopen() async { await OathCloudBackupService.shared.reopenAfterReset() }

    func discardTestWalletConnections() async {
        // Clearing local authorization bindings makes retained SDK sessions
        // unusable for the newly imported vault until the user reconnects.
        UserDefaults.standard.removeObject(forKey: "walletconnect.approvedWallets")
        UserDefaults.standard.removeObject(forKey: "walletconnect.connectionLifecycle.v1")
    }

    func eraseLocalFiles() async throws {
        try await Task.detached(priority: .userInitiated) {
            let namespace = OathInstallationSecurity.appNamespace
            let support = URL.applicationSupportDirectory
            let root = support.appendingPathComponent(namespace, isDirectory: true)
            var targets = [root.appendingPathComponent("CustodyOutbox", isDirectory: true)]
            #if os(iOS)
            // These directories are inside this app's sandbox. Never enumerate
            // Library/Preferences or the iCloud container. The database, prices,
            // settings and current installation key have their own boundaries.
            try OathResetFileCleanup.empty(URL.cachesDirectory)
            try OathResetFileCleanup.empty(URL.temporaryDirectory)
            // Old Oath versions used this ledger path with the same bundle ID.
            // Market caches live separately and are deliberately preserved.
            if namespace == "com.aperture.wallet" {
                targets.append(support.appendingPathComponent("WalletDatabase", isDirectory: true))
                targets.append(support.appendingPathComponent("OathDiagnostics", isDirectory: true))
                try OathInstallationKeychainCleanup.clearLegacyWalletCredentials()
            }
            #endif
            try OathResetFileCleanup.remove(targets)
        }.value
        let db = try await OathDataEnvironment.shared.database()
        try await OathDataEnvironment.seed(db)
    }
}

enum OathResetFileCleanup {
    static func empty(_ directory: URL) throws {
        do {
            if try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                try remove([directory])
                return
            }
            try remove(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
        } catch CocoaError.fileReadNoSuchFile { }
    }

    static func remove(_ targets: [URL]) throws {
        for target in targets {
            // removeItem unlinks a symlink; it does not traverse the target.
            // Only absence is success. Protection and other I/O failures retry.
            do { try FileManager.default.removeItem(at: target) }
            catch CocoaError.fileNoSuchFile { }
        }
    }
}
