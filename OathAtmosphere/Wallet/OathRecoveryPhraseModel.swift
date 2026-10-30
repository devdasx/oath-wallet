import OathDiagnostics
import Foundation
import Observation
import OathCloudBackup

struct OathRecoveryMaterial: Sendable {
    let words: [String]
    let passphrase: String?
    var multisig: BackupWallet.BitcoinMultisig? = nil
    var evmMultisig: BackupWallet.EVMMultisig? = nil
    var tonMultisig: BackupWallet.TonMultisig? = nil
    var thorchainMultisig: BackupWallet.ThorchainMultisig? = nil
    var nearMultisig: BackupWallet.NearMultisig? = nil
    var suiMultisig: BackupWallet.SuiMultisig? = nil
    var aptosMultisig: BackupWallet.AptosMultisig? = nil
    var stellarMultisig: BackupWallet.StellarMultisig? = nil
    var xrplMultisig: BackupWallet.XrplMultisig? = nil
    var tronMultisig: BackupWallet.TronMultisig? = nil
    var solanaMultisig: BackupWallet.SolanaMultisig? = nil
}

protocol OathRecoveryPhraseReading: Sendable {
    func recoveryMaterial(walletID: String, digits: [UInt8]) async throws -> OathRecoveryMaterial
    func recoveryMaterialWithBiometrics(walletID: String, reason: String) async throws -> OathRecoveryMaterial
}

/// Ephemeral, wallet-scoped display data, never a navigation value or SQL row.
/// Every new visit starts with acknowledgement and fresh authentication.
@MainActor @Observable final class OathRecoveryPhraseModel {
    enum Phase: Equatable { case warning, authenticating, passcode, revealed }
    let walletID: String
    private(set) var phase: Phase = .warning
    private(set) var words: [String] = []
    private(set) var multisig: BackupWallet.BitcoinMultisig?
    private(set) var solanaMultisig: BackupWallet.SolanaMultisig?
    private(set) var evmMultisig: BackupWallet.EVMMultisig?
    private(set) var tonMultisig: BackupWallet.TonMultisig?
    private(set) var thorchainMultisig: BackupWallet.ThorchainMultisig?
    private(set) var nearMultisig: BackupWallet.NearMultisig?
    private(set) var suiMultisig: BackupWallet.SuiMultisig?
    private(set) var aptosMultisig: BackupWallet.AptosMultisig?
    private(set) var stellarMultisig: BackupWallet.StellarMultisig?
    private(set) var xrplMultisig: BackupWallet.XrplMultisig?
    private(set) var tronMultisig: BackupWallet.TronMultisig?
    var multisigRecoveryText: String? {
        if let value = evmMultisig { return value.recoveryText }
        if let value = tonMultisig { return value.recoveryText }
        if let value = thorchainMultisig { return value.recoveryText }
        if let value = nearMultisig { return value.recoveryText }
        if let value = suiMultisig { return value.recoveryText }
        if let value = aptosMultisig { return value.recoveryText }
        if let value = stellarMultisig { return value.recoveryText }
        if let value = xrplMultisig { return value.recoveryText }
        if let value = multisig { return value.recoveryText }
        if let value = tronMultisig { return value.recoveryText }
        if let value = solanaMultisig { return value.recoveryText }
        return nil
    }
    private(set) var passphrase: String?
    private(set) var busy = false
    var notice: OathStringKey?
    @ObservationIgnored private let reader: any OathRecoveryPhraseReading
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(walletID: String, reader: any OathRecoveryPhraseReading) {
        self.walletID = walletID
        self.reader = reader
    }

    func acknowledge(reason: String) {
        guard phase == .warning, !busy else { return }
        phase = .authenticating; busy = true; notice = nil
        let token = generation
        work = Task { [weak self, reader, walletID] in
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    // No enrolled item returns .missing without presenting Face ID.
                    // Only an explicitly disabled app lock can skip authorization.
                    let material = try await reader.recoveryMaterialWithBiometrics(walletID: walletID, reason: reason)
                    guard let self, self.isCurrent(token) else { return }
                    self.accept(material)
                } catch {
                    // Missing/declined/unavailable biometrics intentionally offer the
                    // app PIN. Corrupt credentials and unexpected OS failures still report.
                    if (error as? OathBiometricCredentialError)?.isExpectedAuthenticationOutcome != true {
                        OathDiagnostics.record(error, operation: "authorize_recovery", context: ["stage": "biometric"])
                    }
                    guard let self, self.isCurrent(token) else { return }
                    self.busy = false; self.work = nil
                    if error is CancellationError {
                        self.phase = .warning
                    } else if error as? OathWalletError == .locked || error as? OathWalletError == .unavailable {
                        self.phase = .warning; self.notice = .walletUnavailable
                    } else {
                        self.phase = .passcode
                    }
                }
            }
        }
    }

    func submit(_ input: [UInt8]) {
        guard phase == .passcode, !busy, input.count == 6, input.allSatisfy({ $0 <= 9 }) else { return }
        busy = true; notice = nil
        let token = generation
        work = Task { [weak self, reader, walletID] in
            var digits = input
            defer { _ = digits.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
            do {
                let material = try await reader.recoveryMaterial(walletID: walletID, digits: digits)
                guard let self, self.isCurrent(token) else { return }
                self.accept(material)
            } catch { OathDiagnostics.record(error);
                guard let self, self.isCurrent(token) else { return }
                self.busy = false; self.work = nil
                if error is CancellationError { return }
                switch error as? OathWalletError {
                case .wrongPasscode: self.notice = .unlockIncorrect
                case .throttled: self.notice = .unlockWait
                default: self.notice = .walletUnavailable
                }
            }
        }
    }

    func cancelAuthentication() {
        generation = UUID()
        work?.cancel(); work = nil; busy = false; notice = nil
        words.removeAll(); passphrase = nil; multisig = nil; tronMultisig = nil; solanaMultisig = nil; xrplMultisig = nil; stellarMultisig = nil; aptosMultisig = nil; evmMultisig = nil; tonMultisig = nil; thorchainMultisig = nil; nearMultisig = nil; suiMultisig = nil
        if phase == .authenticating || phase == .revealed { phase = .warning }
    }

    func returnToWarning() {
        cancelAuthentication()
        words.removeAll()
        phase = .warning
    }

    func returnToPasscode() {
        cancelAuthentication()
        words.removeAll()
        phase = .passcode
    }

    private func isCurrent(_ token: UUID) -> Bool { token == generation && !Task.isCancelled }

    private func accept(_ material: OathRecoveryMaterial) {
        busy = false; work = nil
        guard material.evmMultisig != nil || material.tonMultisig != nil || material.thorchainMultisig != nil || material.nearMultisig != nil || material.suiMultisig != nil || material.aptosMultisig != nil || !material.words.isEmpty || material.multisig != nil || material.tronMultisig != nil || material.solanaMultisig != nil || material.stellarMultisig != nil || material.xrplMultisig != nil else { phase = .warning; notice = .walletUnavailable; return }
        self.words = material.words
        self.multisig = material.multisig; self.tronMultisig = material.tronMultisig; self.solanaMultisig = material.solanaMultisig; self.xrplMultisig = material.xrplMultisig; self.stellarMultisig = material.stellarMultisig; self.evmMultisig = material.evmMultisig; self.tonMultisig = material.tonMultisig; self.thorchainMultisig = material.thorchainMultisig; self.nearMultisig = material.nearMultisig; suiMultisig = material.suiMultisig; self.aptosMultisig = material.aptosMultisig
        self.passphrase = material.passphrase
        phase = .revealed
    }
}
