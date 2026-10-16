import OathDiagnostics
import Foundation
import Observation

struct OathRecoveryMaterial: Sendable {
    let words: [String]
    let passphrase: String?
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
            do {
                // No enrolled item returns .missing without presenting Face ID.
                // Only an explicitly disabled app lock can skip authorization.
                let material = try await reader.recoveryMaterialWithBiometrics(walletID: walletID, reason: reason)
                guard let self, self.isCurrent(token) else { return }
                self.accept(material)
            } catch { OathDiagnostics.record(error);
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
        words.removeAll(); passphrase = nil
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
        guard !material.words.isEmpty else { phase = .warning; notice = .walletUnavailable; return }
        self.words = material.words
        self.passphrase = material.passphrase
        phase = .revealed
    }
}
