import OathDiagnostics
import Foundation
import Observation
import OathDatabase
import OathBitcoin

/// Human-readable qualifiers are localized in the app; protocol names and BIP
/// identifiers keep their standard spelling across languages.
extension BitcoinAddressType {
    func localizedTitle(using strings: OathLocalizer) -> String {
        switch self {
        case .nativeSegwit: strings.text(.bitcoinNativeSegwit)
        case .legacy: strings.text(.bitcoinLegacy)
        case .taproot, .nestedSegwit: strings.invariant(title)
        }
    }
}

/// Public metadata only. Neither navigation nor the chain list carries secrets.
struct OathPrivateKeyAccount: Identifiable, Equatable, Sendable {
    let id: String
    let chain: OathImportChain
    let address: String
    let path: String
    var utxo: OathPrivateKeyUTXOOrigin? = nil
    var displayName: String {
        guard chain == .solana, let derivation = SolanaDerivation.matching(path: path) else { return chain.name }
        return chain.name + " · " + derivation.title
    }
}

struct OathPrivateKeyUTXOOrigin: Equatable, Sendable {
    let accountID: String
    let accountIndex: UInt32
    let address: BitcoinDerivedAddress
}

struct OathPrivateKeyExport: Sendable {
    let value: String
    let format: String
}

protocol OathPrivateKeyReading: Sendable {
    func privateKeyAccounts(walletID: String) async throws -> [OathPrivateKeyAccount]
    func privateKeyBranches(walletID: String, accountID: String) async throws -> [BitcoinBranch]
    func privateKeyAddresses(walletID: String, accountID: String, branchID: String, after: UInt32?, search: BitcoinAddressSearch) async throws -> [OathPrivateKeyAccount]
    func privateKey(walletID: String, accountID: String, digits: [UInt8]) async throws -> OathPrivateKeyExport
    func privateKeyWithBiometrics(walletID: String, accountID: String, reason: String) async throws -> OathPrivateKeyExport
}

// Non-UTXO readers (including isolated authentication fixtures) do not browse HD paths.
extension OathPrivateKeyReading {
    func privateKeyBranches(walletID: String, accountID: String) async throws -> [BitcoinBranch] { throw OathWalletError.unavailable }
    func privateKeyAddresses(walletID: String, accountID: String, branchID: String, after: UInt32?, search: BitcoinAddressSearch = .init()) async throws -> [OathPrivateKeyAccount] { throw OathWalletError.unavailable }
}

/// A new chain selection always authenticates before the warning. The exported
/// value stays private until acknowledgement and is discarded on leaving.
@MainActor @Observable final class OathPrivateKeyModel {
    enum Phase: Equatable { case chains, authenticating, passcode, warning, revealed }
    let walletID: String
    private(set) var accounts: [OathPrivateKeyAccount] = []
    private(set) var browserAccount: OathPrivateKeyAccount?
    private(set) var branches: [BitcoinBranch] = []
    private(set) var branch: BitcoinBranch?
    private(set) var addresses: [OathPrivateKeyAccount] = []
    private(set) var hasMoreAddresses = false
    private(set) var addressSearch = BitcoinAddressSearch()
    private(set) var selected: OathPrivateKeyAccount?
    private(set) var phase: Phase = .chains
    private(set) var key: OathPrivateKeyExport?
    private(set) var busy = false
    private(set) var loaded = false
    var notice: OathStringKey?
    @ObservationIgnored private let reader: any OathPrivateKeyReading
    @ObservationIgnored private var pendingKey: OathPrivateKeyExport?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(walletID: String, reader: any OathPrivateKeyReading) {
        self.walletID = walletID
        self.reader = reader
    }

    func load() async {
        guard !loaded, !busy, phase == .chains else { return }
        busy = true; notice = nil
        let token = generation
        do {
            let accounts = try await reader.privateKeyAccounts(walletID: walletID)
            guard isCurrent(token) else { return }
            self.accounts = accounts; loaded = true; busy = false
            if accounts.isEmpty { notice = .walletUnavailable }
        } catch { OathDiagnostics.record(error);
            guard isCurrent(token) else { return }
            busy = false
            if !(error is CancellationError) { notice = .walletUnavailable }
        }
    }

    func select(_ account: OathPrivateKeyAccount, reason: String) {
        guard phase == .chains, !busy, (accounts.contains(account) || addresses.contains(account)) else { return }
        selected = account; phase = .authenticating; busy = true; notice = nil
        let token = generation
        work = Task { [weak self, reader, walletID] in
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let key = try await reader.privateKeyWithBiometrics(walletID: walletID, accountID: account.id, reason: reason)
                    guard let self, self.isCurrent(token) else { return }
                    self.accept(key)
                } catch {
                    // Missing/declined/unavailable biometrics intentionally offer the
                    // app PIN. Corrupt credentials and unexpected OS failures still report.
                    if (error as? OathBiometricCredentialError)?.isExpectedAuthenticationOutcome != true {
                        OathDiagnostics.record(error, operation: "authorize_private_key", context: ["stage": "biometric"])
                    }
                    guard let self, self.isCurrent(token) else { return }
                    self.busy = false; self.work = nil
                    if error is CancellationError {
                        self.returnToChains()
                    } else if error is OathBiometricCredentialError {
                        self.phase = .passcode
                    } else {
                        self.returnToChains(); self.notice = .walletUnavailable
                    }
                }
            }
        }
    }

    func submit(_ input: [UInt8]) {
        guard phase == .passcode, !busy, let selected,
              input.count == 6, input.allSatisfy({ $0 <= 9 }) else { return }
        busy = true; notice = nil
        let token = generation
        work = Task { [weak self, reader, walletID] in
            var digits = input
            defer { _ = digits.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
            do {
                let key = try await reader.privateKey(walletID: walletID, accountID: selected.id, digits: digits)
                guard let self, self.isCurrent(token) else { return }
                self.accept(key)
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

    func acknowledge() {
        guard phase == .warning, let pendingKey, !busy else { return }
        key = pendingKey; self.pendingKey = nil; phase = .revealed
    }

    func returnToWarning() {
        // Native Back from the key page keeps the same authorized selection.
        guard phase == .revealed else { return }
        pendingKey = key; key = nil; phase = .warning
    }

    func returnToPasscode() {
        cancelWork(); key = nil; pendingKey = nil; phase = .passcode
    }

    func returnToChains() {
        returnToBrowser()
        browserAccount = nil; branches = []; branch = nil; addresses = []; hasMoreAddresses = false
        addressSearch = .init()
    }

    func returnToBrowser() {
        cancelWork(); key = nil; pendingKey = nil; selected = nil; phase = .chains
    }

    func browse(_ account: OathPrivateKeyAccount) {
        guard phase == .chains, !busy, accounts.contains(account), UTXONetwork(rawValue: account.chain.id) != nil else { return }
        returnToChains(); browserAccount = account
    }

    func loadBranches() async {
        guard let account = browserAccount, branches.isEmpty, !busy else { return }
        busy = true; notice = nil
        let token = generation
        do {
            let result = try await reader.privateKeyBranches(walletID: walletID, accountID: account.id)
            guard token == generation else { return }
            guard !Task.isCancelled else { busy = false; return }
            branches = result; busy = false
            if result.isEmpty { notice = .walletUnavailable }
        } catch { OathDiagnostics.record(error);
            guard token == generation else { return }
            guard !Task.isCancelled else { busy = false; return }
            busy = false
            if !(error is CancellationError) { notice = .walletUnavailable }
        }
    }

    func chooseBranch(_ value: BitcoinBranch) {
        guard branches.contains(value), value != branch else { return }
        returnToBrowser(); branch = value; addresses = []; hasMoreAddresses = true
    }

    func setAddressSearch(_ search: BitcoinAddressSearch) {
        guard phase == .chains, addressSearch != search else { return }
        // Invalidate a previous read before resetting its page. Late results
        // from another query/branch must never replace the current list.
        returnToBrowser()
        addressSearch = search; addresses = []; hasMoreAddresses = branch != nil
    }

    func loadAddresses() async {
        guard let account = browserAccount, let branch, hasMoreAddresses, !busy, phase == .chains else { return }
        busy = true; notice = nil
        let token = generation
        do {
            let result = try await reader.privateKeyAddresses(walletID: walletID, accountID: account.id,
                branchID: branch.id, after: addresses.last?.utxo?.address.index, search: addressSearch)
            guard token == generation else { return }
            guard !Task.isCancelled else { busy = false; return }
            addresses += result; hasMoreAddresses = result.count == 50; busy = false
        } catch {
            // Superseded searches and disappearing pages are expected teardown;
            // never report the user's address query or public address metadata.
            if !(error is CancellationError) {
                OathDiagnostics.record(error, component: "private_key_browser", operation: "load_addresses")
            }
            guard token == generation else { return }
            guard !Task.isCancelled else { busy = false; return }
            busy = false
            if !(error is CancellationError) { notice = .walletUnavailable }
        }
    }

    func cancelAuthentication() {
        // Preserve an already revealed page beneath the app lock, as requested
        // by the app's snapshot policy. Unacknowledged results are not retained.
        if phase != .revealed { returnToChains() }
    }

    private func cancelWork() {
        generation = UUID(); work?.cancel(); work = nil; busy = false; notice = nil
    }

    private func isCurrent(_ token: UUID) -> Bool { token == generation && !Task.isCancelled }

    private func accept(_ key: OathPrivateKeyExport) {
        busy = false; work = nil
        guard !key.value.isEmpty else { returnToChains(); notice = .walletUnavailable; return }
        pendingKey = key; phase = .warning
    }
}
