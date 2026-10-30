import SwiftUI
import Observation
import OathAnkr
import OathBitcoin
import OathCloudBackup
import OathDiagnostics

@MainActor @Observable final class OathMultisigDraft {
    enum Chain { case evm, ton, bitcoin, litecoin, bitcoincash, dogecoin, tron, solana, xrpl, stellar, aptos, sui, near, thorchain }
    var chain: Chain = .bitcoin
    var evmNetwork: EVMSendNetwork = .ethereum
    var maximumKeys: Int { chain == .evm ? EVMMultisigPolicy.maximumKeys : chain == .ton ? TonMultisigPolicy.maximumKeys : chain == .thorchain ? ThorchainMultisigPolicy.maximumKeys : chain == .near ? NearMultisigPolicy.maximumKeys : chain == .sui ? SuiMultisigPolicy.maximumKeys : chain == .aptos ? AptosMultisigPolicy.maximumKeys : chain == .stellar ? StellarMultisigPolicy.maximumKeys : chain == .xrpl ? XrplMultisigPolicy.maximumKeys : chain == .solana ? SolanaMultisigPolicy.maximumKeys : chain == .tron ? TronMultisigPolicy.maximumKeys : BitcoinMultisig.maximumKeys }
    enum Source: String, CaseIterable, Identifiable { case fresh, wif, phrase; var id: Self { self } }
    struct Slot: Identifiable {
        let id = UUID()
        var source: Source = .fresh
        var input = ""
        var passphrase = ""
        var material: BackupWallet.BitcoinMultisig.Signer?
        var evmMaterial: BackupWallet.EVMMultisig.Signer?
        var tonMaterial: BackupWallet.TonMultisig.Signer?
        var thorchainMaterial: BackupWallet.ThorchainMultisig.Signer?
        var nearMaterial: BackupWallet.NearMultisig.Signer?
        var suiMaterial: BackupWallet.SuiMultisig.Signer?
        var aptosMaterial: BackupWallet.AptosMultisig.Signer?
        var stellarMaterial: BackupWallet.StellarMultisig.Signer?
        var xrplMaterial: BackupWallet.XrplMultisig.Signer?
        var solanaMaterial: BackupWallet.SolanaMultisig.Signer?
        var tronMaterial: BackupWallet.TronMultisig.Signer?
        var isReady: Bool { evmMaterial != nil || tonMaterial != nil || thorchainMaterial != nil || nearMaterial != nil || suiMaterial != nil || aptosMaterial != nil || stellarMaterial != nil || xrplMaterial != nil || material != nil || tronMaterial != nil || solanaMaterial != nil }
        var notice: OathStringKey?
    }
    var required = 2
    var slots = [Slot(), Slot(), Slot()]
    private(set) var working: UUID?
    private(set) var preparing = false
    var notice: OathStringKey?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    var ready: Bool { slots.allSatisfy { chain == .evm ? $0.evmMaterial != nil : chain == .ton ? $0.tonMaterial != nil : chain == .thorchain ? $0.thorchainMaterial != nil : chain == .near ? $0.nearMaterial != nil : chain == .sui ? $0.suiMaterial != nil : chain == .aptos ? $0.aptosMaterial != nil : chain == .stellar ? $0.stellarMaterial != nil : chain == .xrpl ? $0.xrplMaterial != nil : chain == .solana ? $0.solanaMaterial != nil : chain == .tron ? $0.tronMaterial != nil : $0.material != nil } && working == nil && !preparing }

    func resize(_ count: Int) {
        guard working == nil, !preparing, (2...maximumKeys).contains(count) else { return }
        if count < slots.count { slots.removeLast(slots.count - count) }
        else { slots += (slots.count..<count).map { _ in Slot() } }
        required = min(required, count); notice = nil
    }
    func changeSource(_ source: Source, at index: Int) {
        guard slots.indices.contains(index), working == nil, !preparing else { return }
        slots[index].source = source; slots[index].input = ""; slots[index].passphrase = ""
        slots[index].evmMaterial = nil; slots[index].tonMaterial = nil; slots[index].thorchainMaterial = nil; slots[index].nearMaterial = nil; slots[index].suiMaterial = nil; slots[index].aptosMaterial = nil; slots[index].stellarMaterial = nil; slots[index].xrplMaterial = nil; slots[index].solanaMaterial = nil; slots[index].tronMaterial = nil; slots[index].material = nil; slots[index].notice = nil; notice = nil
    }
    func prepareKey(at index: Int) {
        if chain == .evm { prepareEVMKey(at: index); return }
        if chain == .ton { prepareTonKey(at: index); return }
        if chain == .thorchain { prepareThorchainKey(at: index); return }
        if chain == .near { prepareNearKey(at: index); return }
        if chain == .sui { prepareSuiKey(at: index); return }
        if chain == .aptos { prepareAptosKey(at: index); return }
        if chain == .stellar { prepareStellarKey(at: index); return }
        if chain == .xrpl { prepareXrplKey(at: index); return }
        if chain == .solana { prepareSolanaKey(at: index); return }
        if chain == .tron { prepareTronKey(at: index); return }
        guard slots.indices.contains(index), working == nil, !preparing else { return }
        let slot = slots[index], token = generation, operationID = UUID()
        let network: UTXONetwork = chain == .dogecoin ? .dogecoin : chain == .bitcoincash ? .bitcoincash : chain == .litecoin ? .litecoin : .bitcoin
        working = slot.id; slots[index].notice = nil; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) { () throws -> BackupWallet.BitcoinMultisig.Signer in
                try OathDiagnostics.$operationID.withValue(operationID) {
                  try OathDiagnostics.$chain.withValue(network.rawValue) {
                    try Task.checkCancellation()
                    switch slot.source {
                case .fresh:
                    let created = try OathWalletEngine.create()
                    return .init(mnemonic: created.mnemonic, language: created.language)
                case .wif:
                    let text = slot.input.trimmingCharacters(in: .whitespacesAndNewlines)
                    try BitcoinMultisig.validateWIF(text, network: network)
                    return .init(wif: text)
                case .phrase:
                    guard let phrase = OathMnemonicValidator.bundled?.verifiedPhrase(slot.input) else { throw OathWalletError.invalidPhrase }
                    let passphrase = slot.passphrase.isEmpty ? nil : try RecoveryPassphrase.normalized(slot.passphrase)
                    return .init(mnemonic: phrase.phrase, language: phrase.language, passphrase: passphrase)
                    }
                  }
                }
            }
            do {
                let key = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index), slots[index].id == slot.id else { return }
                slots[index].material = key; slots[index].input = ""; slots[index].passphrase = ""
            } catch {
                // Invalid user input and cancellation are expected form outcomes.
                if slot.source == .fresh, !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(DiagnosticFailure("multisig_key_generation_failed"),
                            component: "wallet", operation: "create_multisig_key", context: ["chain": network.rawValue])
                    }
                }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index) else { return }
                slots[index].notice = error is RecoveryPassphraseError ? .passphraseInvalid : slot.source == .fresh ? .walletUnavailable : slot.source == .wif ? .privateKeyInvalid : .scannerInvalidRecovery
            }
            guard generation == token else { return }
            working = nil; task = nil
        }
    }
    func finish(_ onReady: @escaping (BackupWallet.BitcoinMultisig) -> Void) {
        guard chain == .bitcoin || chain == .litecoin || chain == .bitcoincash || chain == .dogecoin, ready else { return }
        let network: UTXONetwork = chain == .dogecoin ? .dogecoin : chain == .bitcoincash ? .bitcoincash : chain == .litecoin ? .litecoin : .bitcoin
        let material = BackupWallet.BitcoinMultisig(required: required, signers: slots.compactMap(\.material), network: network == .bitcoin ? nil : network.rawValue)
        let token = generation, operationID = UUID()
        preparing = true; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) {
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue(network.rawValue) { _ = try material.descriptor() }
                }
            }
            do {
                try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled else { return }
                preparing = false; task = nil; onReady(material)
            } catch {
                // Duplicate keys are expected validation, not a diagnostic event.
                if !(error is CancellationError), (error as? BitcoinMultisigError) != .duplicateKey {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(DiagnosticFailure("multisig_policy_validation_failed"),
                            component: "wallet", operation: "prepare_multisig", context: ["chain": network.rawValue])
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                notice = (error as? BitcoinMultisigError) == .duplicateKey ? .multisigDuplicateKey : .walletUnavailable
                preparing = false; task = nil
            }
        }
    }
    private func prepareNearKey(at index: Int) {
        guard slots.indices.contains(index), working == nil, !preparing else { return }
        let slot = slots[index], token = generation, operationID = UUID()
        working = slot.id; slots[index].notice = nil; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) { () throws -> BackupWallet.NearMultisig.Signer in
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("near") {
                        try Task.checkCancellation()
                        switch slot.source {
                        case .fresh:
                            return try .phrase(OathWalletEngine.create().mnemonic, passphrase: nil)
                        case .phrase:
                            return try .phrase(slot.input, passphrase: slot.passphrase.isEmpty ? nil : RecoveryPassphrase.normalized(slot.passphrase))
                        case .wif:
                            let text = slot.input.trimmingCharacters(in: .whitespacesAndNewlines)
                            let key = try BackupWallet.NearMultisig.Signer.importedKey(text)
                            guard key.count == 32 else { throw OathWalletError.invalidPrivateKey }
                            return try .init(publicKey: NearSendCrypto.publicKey(privateKey: key), key: key)
                        }
                    }
                }
            }
            do {
                let key = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index), slots[index].id == slot.id else { return }
                if slots.contains(where: { $0.nearMaterial?.publicKey == key.publicKey }) {
                    slots[index].notice = .multisigDuplicateKey
                } else {
                    slots[index].nearMaterial = key; slots[index].input = ""; slots[index].passphrase = ""
                }
            } catch {
                // Imported key validation and cancellation are expected form outcomes.
                if slot.source == .fresh, !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(error,
                            component: "wallet", operation: "create_multisig_key", context: ["chain": "near"])
                    }
                }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index) else { return }
                slots[index].notice = error is RecoveryPassphraseError ? .passphraseInvalid : slot.source == .fresh ? .walletUnavailable : slot.source == .wif ? .privateKeyInvalid : .scannerInvalidRecovery
            }
            guard generation == token else { return }
            working = nil; task = nil
        }
    }
    func finishNear(_ onReady: @escaping (BackupWallet.NearMultisig) -> Void) {
        guard chain == .near, ready else { return }
        let signers = slots.compactMap(\.nearMaterial), required = required, token = generation, operationID = UUID()
        preparing = true; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) {
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("near") {
                        try Task.checkCancellation()
                        let bootstrap = NearMultisigPolicy.freshBootstrapSeed()
                        let policy = try NearMultisigPolicy(bootstrap: NearSendCrypto.publicKey(privateKey: bootstrap), required: required, publicKeys: signers.map(\.publicKey))
                        let material = BackupWallet.NearMultisig(bootstrapSeed: bootstrap, required: required, address: policy.address, signers: signers)
                        try material.validateMaterial()
                        return material
                    }
                }
            }
            do {
                let material = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled else { return }
                preparing = false; task = nil; onReady(material)
            } catch {
                if !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(error,
                            component: "wallet", operation: "prepare_multisig", context: ["chain": "near"])
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                notice = .walletUnavailable; preparing = false; task = nil
            }
        }
    }
    private func prepareTonKey(at index: Int) {
        guard slots.indices.contains(index), working == nil, !preparing else { return }
        let slot = slots[index], token = generation, operationID = UUID()
        working = slot.id; slots[index].notice = nil; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) { () throws -> BackupWallet.TonMultisig.Signer in
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("ton") {
                        try Task.checkCancellation()
                        switch slot.source {
                        case .fresh:
                            return try .phrase(OathWalletEngine.create().mnemonic, passphrase: nil)
                        case .phrase:
                            return try .phrase(slot.input, passphrase: slot.passphrase.isEmpty ? nil : RecoveryPassphrase.normalized(slot.passphrase))
                        case .wif:
                            let text = slot.input.trimmingCharacters(in: .whitespacesAndNewlines)
                            let key = try BackupWallet.TonMultisig.Signer.importedKey(text)
                            guard key.count == 32 else { throw OathWalletError.invalidPrivateKey }
                            return try .init(publicKey: TonSendCrypto.publicKey(privateKey: key), key: key)
                        }
                    }
                }
            }
            do {
                let key = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index), slots[index].id == slot.id else { return }
                if slots.contains(where: { $0.tonMaterial?.publicKey == key.publicKey }) {
                    slots[index].notice = .multisigDuplicateKey
                } else {
                    slots[index].tonMaterial = key; slots[index].input = ""; slots[index].passphrase = ""
                }
            } catch {
                // Imported key validation and cancellation are expected form outcomes.
                if slot.source == .fresh, !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(error,
                            component: "wallet", operation: "create_multisig_key", context: ["chain": "ton"])
                    }
                }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index) else { return }
                slots[index].notice = error is RecoveryPassphraseError ? .passphraseInvalid : slot.source == .fresh ? .walletUnavailable : slot.source == .wif ? .privateKeyInvalid : .scannerInvalidRecovery
            }
            guard generation == token else { return }
            working = nil; task = nil
        }
    }
    func finishTon(_ onReady: @escaping (BackupWallet.TonMultisig) -> Void) {
        guard chain == .ton, ready else { return }
        let signers = slots.compactMap(\.tonMaterial), required = required, token = generation, operationID = UUID()
        preparing = true; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) {
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("ton") {
                        try Task.checkCancellation()
                        let policy = try TonMultisigPolicy(required: required, publicKeys: signers.map(\.publicKey))
                        let material = try BackupWallet.TonMultisig(required: required, address: policy.address(network: .mainnet), signers: signers)
                        try material.validateMaterial()
                        return material
                    }
                }
            }
            do {
                let material = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled else { return }
                preparing = false; task = nil; onReady(material)
            } catch {
                if !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(error,
                            component: "wallet", operation: "prepare_multisig", context: ["chain": "ton"])
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                notice = .walletUnavailable; preparing = false; task = nil
            }
        }
    }
    private func prepareThorchainKey(at index: Int) {
        guard slots.indices.contains(index), working == nil, !preparing else { return }
        let slot = slots[index], token = generation, operationID = UUID()
        working = slot.id; slots[index].notice = nil; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) { () throws -> BackupWallet.ThorchainMultisig.Signer in
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("thorchain") {
                        try Task.checkCancellation()
                        switch slot.source {
                        case .fresh:
                            return try .phrase(OathWalletEngine.create().mnemonic, passphrase: nil)
                        case .phrase:
                            return try .phrase(slot.input, passphrase: slot.passphrase.isEmpty ? nil : RecoveryPassphrase.normalized(slot.passphrase))
                        case .wif:
                            let text = slot.input.trimmingCharacters(in: .whitespacesAndNewlines)
                            let key = try BackupWallet.ThorchainMultisig.Signer.importedKey(text)
                            guard key.count == 32 else { throw OathWalletError.invalidPrivateKey }
                            return try .init(publicKey: ThorchainSendCrypto.publicKey(privateKey: key), key: key)
                        }
                    }
                }
            }
            do {
                let key = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index), slots[index].id == slot.id else { return }
                if slots.contains(where: { $0.thorchainMaterial?.publicKey == key.publicKey }) {
                    slots[index].notice = .multisigDuplicateKey
                } else {
                    slots[index].thorchainMaterial = key; slots[index].input = ""; slots[index].passphrase = ""
                }
            } catch {
                // Imported key validation and cancellation are expected form outcomes.
                if slot.source == .fresh, !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(error,
                            component: "wallet", operation: "create_multisig_key", context: ["chain": "thorchain"])
                    }
                }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index) else { return }
                slots[index].notice = error is RecoveryPassphraseError ? .passphraseInvalid : slot.source == .fresh ? .walletUnavailable : slot.source == .wif ? .privateKeyInvalid : .scannerInvalidRecovery
            }
            guard generation == token else { return }
            working = nil; task = nil
        }
    }
    func finishThorchain(_ onReady: @escaping (BackupWallet.ThorchainMultisig) -> Void) {
        guard chain == .thorchain, ready else { return }
        let signers = slots.compactMap(\.thorchainMaterial), required = required, token = generation, operationID = UUID()
        preparing = true; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) {
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("thorchain") {
                        try Task.checkCancellation()
                        let policy = try ThorchainMultisigPolicy(required: required, publicKeys: signers.map(\.publicKey))
                        let material = BackupWallet.ThorchainMultisig(required: required, address: policy.address(network: .mainnet), signers: signers)
                        try material.validateMaterial()
                        return material
                    }
                }
            }
            do {
                let material = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled else { return }
                preparing = false; task = nil; onReady(material)
            } catch {
                if !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(error,
                            component: "wallet", operation: "prepare_multisig", context: ["chain": "thorchain"])
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                notice = .walletUnavailable; preparing = false; task = nil
            }
        }
    }
    private func prepareSuiKey(at index: Int) {
        guard slots.indices.contains(index), working == nil, !preparing else { return }
        let slot = slots[index], token = generation, operationID = UUID()
        working = slot.id; slots[index].notice = nil; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) { () throws -> BackupWallet.SuiMultisig.Signer in
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("sui") {
                        try Task.checkCancellation()
                        switch slot.source {
                        case .fresh:
                            return try .phrase(OathWalletEngine.create().mnemonic, passphrase: nil)
                        case .phrase:
                            return try .phrase(slot.input, passphrase: slot.passphrase.isEmpty ? nil : RecoveryPassphrase.normalized(slot.passphrase))
                        case .wif:
                            let text = slot.input.trimmingCharacters(in: .whitespacesAndNewlines)
                            let key = try BackupWallet.SuiMultisig.Signer.importedKey(text)
                            guard key.count == 32 else { throw OathWalletError.invalidPrivateKey }
                            return try .init(publicKey: SuiSendCrypto.publicKey(privateKey: key), key: key)
                        }
                    }
                }
            }
            do {
                let key = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index), slots[index].id == slot.id else { return }
                if slots.contains(where: { $0.suiMaterial?.publicKey == key.publicKey }) {
                    slots[index].notice = .multisigDuplicateKey
                } else {
                    slots[index].suiMaterial = key; slots[index].input = ""; slots[index].passphrase = ""
                }
            } catch {
                // Imported key validation and cancellation are expected form outcomes.
                if slot.source == .fresh, !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(error,
                            component: "wallet", operation: "create_multisig_key", context: ["chain": "sui"])
                    }
                }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index) else { return }
                slots[index].notice = error is RecoveryPassphraseError ? .passphraseInvalid : slot.source == .fresh ? .walletUnavailable : slot.source == .wif ? .privateKeyInvalid : .scannerInvalidRecovery
            }
            guard generation == token else { return }
            working = nil; task = nil
        }
    }
    func finishSui(_ onReady: @escaping (BackupWallet.SuiMultisig) -> Void) {
        guard chain == .sui, ready else { return }
        let signers = slots.compactMap(\.suiMaterial), required = required, token = generation, operationID = UUID()
        preparing = true; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) {
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("sui") {
                        try Task.checkCancellation()
                        let policy = try SuiMultisigPolicy(required: required, publicKeys: signers.map(\.publicKey))
                        let material = BackupWallet.SuiMultisig(required: required, address: policy.address, signers: signers)
                        try material.validateMaterial()
                        return material
                    }
                }
            }
            do {
                let material = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled else { return }
                preparing = false; task = nil; onReady(material)
            } catch {
                if !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(error,
                            component: "wallet", operation: "prepare_multisig", context: ["chain": "sui"])
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                notice = .walletUnavailable; preparing = false; task = nil
            }
        }
    }
    private func prepareAptosKey(at index: Int) {
        guard slots.indices.contains(index), working == nil, !preparing else { return }
        let slot = slots[index], token = generation, operationID = UUID()
        working = slot.id; slots[index].notice = nil; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) { () throws -> BackupWallet.AptosMultisig.Signer in
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("aptos") {
                        try Task.checkCancellation()
                        switch slot.source {
                        case .fresh:
                            return try .phrase(OathWalletEngine.create().mnemonic, passphrase: nil)
                        case .phrase:
                            return try .phrase(slot.input, passphrase: slot.passphrase.isEmpty ? nil : RecoveryPassphrase.normalized(slot.passphrase))
                        case .wif:
                            let text = slot.input.trimmingCharacters(in: .whitespacesAndNewlines)
                            let normalized = text.hasPrefix("ed25519-priv-") ? String(text.dropFirst(13)) : text
                            let key = try TronIdentity.hex(normalized)
                            guard key.count == 32 else { throw OathWalletError.invalidPrivateKey }
                            return try .init(publicKey: AptosSendCrypto.publicKey(privateKey: key), key: key)
                        }
                    }
                }
            }
            do {
                let key = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index), slots[index].id == slot.id else { return }
                if slots.contains(where: { $0.aptosMaterial?.publicKey == key.publicKey }) {
                    slots[index].notice = .multisigDuplicateKey
                } else {
                    slots[index].aptosMaterial = key; slots[index].input = ""; slots[index].passphrase = ""
                }
            } catch {
                // Imported key validation and cancellation are expected form outcomes.
                if slot.source == .fresh, !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(DiagnosticFailure("multisig_key_generation_failed"),
                            component: "wallet", operation: "create_multisig_key", context: ["chain": "aptos"])
                    }
                }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index) else { return }
                slots[index].notice = error is RecoveryPassphraseError ? .passphraseInvalid : slot.source == .fresh ? .walletUnavailable : slot.source == .wif ? .privateKeyInvalid : .scannerInvalidRecovery
            }
            guard generation == token else { return }
            working = nil; task = nil
        }
    }
    func finishAptos(_ onReady: @escaping (BackupWallet.AptosMultisig) -> Void) {
        guard chain == .aptos, ready else { return }
        let signers = slots.compactMap(\.aptosMaterial), required = required, token = generation, operationID = UUID()
        preparing = true; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) {
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("aptos") {
                        try Task.checkCancellation()
                        let policy = try AptosMultisigPolicy(required: required, publicKeys: signers.map(\.publicKey))
                        let material = BackupWallet.AptosMultisig(required: required, address: policy.address, signers: signers)
                        try material.validateMaterial()
                        return material
                    }
                }
            }
            do {
                let material = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled else { return }
                preparing = false; task = nil; onReady(material)
            } catch {
                if !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(DiagnosticFailure("multisig_policy_validation_failed"),
                            component: "wallet", operation: "prepare_multisig", context: ["chain": "aptos"])
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                notice = .walletUnavailable; preparing = false; task = nil
            }
        }
    }
    private func prepareStellarKey(at index: Int) {
        guard slots.indices.contains(index), working == nil, !preparing else { return }
        let slot = slots[index], token = generation, operationID = UUID()
        working = slot.id; slots[index].notice = nil; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) { () throws -> BackupWallet.StellarMultisig.Signer in
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("stellar") {
                        try Task.checkCancellation()
                        switch slot.source {
                        case .fresh:
                            return try .phrase(OathWalletEngine.create().mnemonic, passphrase: nil)
                        case .phrase:
                            return try .phrase(slot.input, passphrase: slot.passphrase.isEmpty ? nil : RecoveryPassphrase.normalized(slot.passphrase))
                        case .wif:
                            let text = slot.input.trimmingCharacters(in: .whitespacesAndNewlines)
                            let key = try Data(StellarIdentity.bytes(text, version: 144))
                            return try .init(address: StellarSendCrypto.address(privateKey: key), key: key)
                        }
                    }
                }
            }
            do {
                let key = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index), slots[index].id == slot.id else { return }
                if slots.contains(where: { $0.stellarMaterial?.address == key.address }) {
                    slots[index].notice = .multisigDuplicateKey
                } else {
                    slots[index].stellarMaterial = key; slots[index].input = ""; slots[index].passphrase = ""
                }
            } catch {
                // Imported key validation and cancellation are expected form outcomes.
                if slot.source == .fresh, !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(DiagnosticFailure("multisig_key_generation_failed"),
                            component: "wallet", operation: "create_multisig_key", context: ["chain": "stellar"])
                    }
                }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index) else { return }
                slots[index].notice = error is RecoveryPassphraseError ? .passphraseInvalid : slot.source == .fresh ? .walletUnavailable : slot.source == .wif ? .privateKeyInvalid : .scannerInvalidRecovery
            }
            guard generation == token else { return }
            working = nil; task = nil
        }
    }
    func finishStellar(_ onReady: @escaping (BackupWallet.StellarMultisig) -> Void) {
        guard chain == .stellar, ready else { return }
        let signers = slots.compactMap(\.stellarMaterial), required = required, token = generation, operationID = UUID()
        preparing = true; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) {
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("stellar") {
                        try Task.checkCancellation()
                        let bootstrap = try BackupWallet.StellarMultisig.Signer.phrase(OathWalletEngine.create().mnemonic, passphrase: nil)
                        var key = try bootstrap.signingKey(); defer { key.resetBytes(in: 0..<key.count) }
                        let material = BackupWallet.StellarMultisig(required: required, accountKey: key, address: bootstrap.address, signers: signers)
                        try material.validateMaterial()
                        return material
                    }
                }
            }
            do {
                let material = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled else { return }
                preparing = false; task = nil; onReady(material)
            } catch {
                if !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(DiagnosticFailure("multisig_policy_validation_failed"),
                            component: "wallet", operation: "prepare_multisig", context: ["chain": "stellar"])
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                notice = .walletUnavailable; preparing = false; task = nil
            }
        }
    }
    private func prepareXrplKey(at index: Int) {
        guard slots.indices.contains(index), working == nil, !preparing else { return }
        let slot = slots[index], token = generation, operationID = UUID()
        working = slot.id; slots[index].notice = nil; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) { () throws -> BackupWallet.XrplMultisig.Signer in
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("xrpl") {
                        try Task.checkCancellation()
                        switch slot.source {
                        case .fresh:
                            return try .phrase(OathWalletEngine.create().mnemonic, passphrase: nil)
                        case .phrase:
                            return try .phrase(slot.input, passphrase: slot.passphrase.isEmpty ? nil : RecoveryPassphrase.normalized(slot.passphrase))
                        case .wif:
                            let text = slot.input.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard text.count == 64 else { throw OathWalletError.invalidPrivateKey }
                            let key = try TronIdentity.hex(text)
                            return try .init(address: XrplSendCrypto.address(privateKey: key), key: key)
                        }
                    }
                }
            }
            do {
                let key = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index), slots[index].id == slot.id else { return }
                if slots.contains(where: { $0.xrplMaterial?.address == key.address }) {
                    slots[index].notice = .multisigDuplicateKey
                } else {
                    slots[index].xrplMaterial = key; slots[index].input = ""; slots[index].passphrase = ""
                }
            } catch {
                // Imported key validation and cancellation are expected form outcomes.
                if slot.source == .fresh, !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(DiagnosticFailure("multisig_key_generation_failed"),
                            component: "wallet", operation: "create_multisig_key", context: ["chain": "xrpl"])
                    }
                }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index) else { return }
                slots[index].notice = error is RecoveryPassphraseError ? .passphraseInvalid : slot.source == .fresh ? .walletUnavailable : slot.source == .wif ? .privateKeyInvalid : .scannerInvalidRecovery
            }
            guard generation == token else { return }
            working = nil; task = nil
        }
    }
    func finishXrpl(_ onReady: @escaping (BackupWallet.XrplMultisig) -> Void) {
        guard chain == .xrpl, ready else { return }
        let signers = slots.compactMap(\.xrplMaterial), required = required, token = generation, operationID = UUID()
        preparing = true; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) {
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("xrpl") {
                        try Task.checkCancellation()
                        let bootstrap = try BackupWallet.XrplMultisig.Signer.phrase(OathWalletEngine.create().mnemonic, passphrase: nil)
                        var key = try bootstrap.signingKey(); defer { key.resetBytes(in: 0..<key.count) }
                        let material = BackupWallet.XrplMultisig(required: required, accountKey: key, address: bootstrap.address, signers: signers)
                        try material.validateMaterial()
                        return material
                    }
                }
            }
            do {
                let material = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled else { return }
                preparing = false; task = nil; onReady(material)
            } catch {
                if !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(DiagnosticFailure("multisig_policy_validation_failed"),
                            component: "wallet", operation: "prepare_multisig", context: ["chain": "xrpl"])
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                notice = .walletUnavailable; preparing = false; task = nil
            }
        }
    }
    private func prepareEVMKey(at index: Int) {
        guard slots.indices.contains(index), working == nil, !preparing else { return }
        let slot = slots[index], token = generation, operationID = UUID(), network = evmNetwork
        working = slot.id; slots[index].notice = nil; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) { () throws -> BackupWallet.EVMMultisig.Signer in
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue(network.rawValue) {
                        try Task.checkCancellation()
                        switch slot.source {
                        case .fresh:
                            return try .phrase(OathWalletEngine.create().mnemonic, passphrase: nil)
                        case .phrase:
                            return try .phrase(slot.input, passphrase: slot.passphrase.isEmpty ? nil : RecoveryPassphrase.normalized(slot.passphrase))
                        case .wif:
                            let text = slot.input.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard text.count == 64 || (text.hasPrefix("0x") && text.count == 66) else { throw OathWalletError.invalidPrivateKey }
                            let key = try TronIdentity.hex(text)
                            return try .init(address: EVMSendCrypto.address(privateKey: key), key: key)
                        }
                    }
                }
            }
            do {
                let key = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index), slots[index].id == slot.id else { return }
                if slots.contains(where: { $0.evmMaterial?.address == key.address }) {
                    slots[index].notice = .multisigDuplicateKey
                } else {
                    slots[index].evmMaterial = key; slots[index].input = ""; slots[index].passphrase = ""
                }
            } catch {
                // Imported key validation and cancellation are expected form outcomes.
                if slot.source == .fresh, !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(DiagnosticFailure("multisig_key_generation_failed"),
                            component: "wallet", operation: "create_multisig_key", context: ["chain": network.rawValue])
                    }
                }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index) else { return }
                slots[index].notice = error is RecoveryPassphraseError ? .passphraseInvalid : slot.source == .fresh ? .walletUnavailable : slot.source == .wif ? .privateKeyInvalid : .scannerInvalidRecovery
            }
            guard generation == token else { return }
            working = nil; task = nil
        }
    }
    func finishEVM(_ onReady: @escaping (BackupWallet.EVMMultisig) -> Void) {
        guard chain == .evm, ready else { return }
        let signers = slots.compactMap(\.evmMaterial), required = required, token = generation, operationID = UUID(), network = evmNetwork
        preparing = true; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) {
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue(network.rawValue) {
                        try Task.checkCancellation()
                        let bootstrap = try BackupWallet.EVMMultisig.Signer.phrase(OathWalletEngine.create().mnemonic, passphrase: nil)
                        var key = try bootstrap.signingKey(); defer { key.resetBytes(in: 0..<key.count) }
                        let salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
                        let policy = try EVMMultisigPolicy(required: required, owners: signers.map(\.address), salt: salt, executor: bootstrap.address)
                        let material = BackupWallet.EVMMultisig(network: network.rawValue, salt: salt, required: required, executorKey: key, address: try policy.address, signers: signers)
                        try material.validateMaterial()
                        return material
                    }
                }
            }
            do {
                let material = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled else { return }
                preparing = false; task = nil; onReady(material)
            } catch {
                if !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(DiagnosticFailure("multisig_policy_validation_failed"),
                            component: "wallet", operation: "prepare_multisig", context: ["chain": network.rawValue])
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                notice = .walletUnavailable; preparing = false; task = nil
            }
        }
    }
    private func prepareTronKey(at index: Int) {
        guard slots.indices.contains(index), working == nil, !preparing else { return }
        let slot = slots[index], token = generation, operationID = UUID()
        working = slot.id; slots[index].notice = nil; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) { () throws -> BackupWallet.TronMultisig.Signer in
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("tron") {
                        try Task.checkCancellation()
                        switch slot.source {
                        case .fresh:
                            return try .phrase(OathWalletEngine.create().mnemonic, passphrase: nil)
                        case .phrase:
                            return try .phrase(slot.input, passphrase: slot.passphrase.isEmpty ? nil : RecoveryPassphrase.normalized(slot.passphrase))
                        case .wif:
                            let text = slot.input.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard text.count == 64 else { throw OathWalletError.invalidPrivateKey }
                            let key = try TronIdentity.hex(text)
                            return try .init(address: TronSendCrypto.address(privateKey: key), key: key)
                        }
                    }
                }
            }
            do {
                let key = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index), slots[index].id == slot.id else { return }
                if slots.contains(where: { $0.tronMaterial?.address == key.address }) {
                    slots[index].notice = .multisigDuplicateKey
                } else {
                    slots[index].tronMaterial = key; slots[index].input = ""; slots[index].passphrase = ""
                }
            } catch {
                // Imported key validation and cancellation are expected form outcomes.
                if slot.source == .fresh, !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(DiagnosticFailure("multisig_key_generation_failed"),
                            component: "wallet", operation: "create_multisig_key", context: ["chain": "tron"])
                    }
                }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index) else { return }
                slots[index].notice = error is RecoveryPassphraseError ? .passphraseInvalid : slot.source == .fresh ? .walletUnavailable : slot.source == .wif ? .privateKeyInvalid : .scannerInvalidRecovery
            }
            guard generation == token else { return }
            working = nil; task = nil
        }
    }
    func finishTron(_ onReady: @escaping (BackupWallet.TronMultisig) -> Void) {
        guard chain == .tron, ready else { return }
        let signers = slots.compactMap(\.tronMaterial), required = required, token = generation, operationID = UUID()
        preparing = true; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) {
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("tron") {
                        try Task.checkCancellation()
                        let bootstrap = try BackupWallet.TronMultisig.Signer.phrase(OathWalletEngine.create().mnemonic, passphrase: nil)
                        var key = try bootstrap.signingKey(); defer { key.resetBytes(in: 0..<key.count) }
                        let material = BackupWallet.TronMultisig(required: required, accountKey: key, address: bootstrap.address, signers: signers)
                        try material.validateMaterial()
                        return material
                    }
                }
            }
            do {
                let material = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled else { return }
                preparing = false; task = nil; onReady(material)
            } catch {
                if !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(DiagnosticFailure("multisig_policy_validation_failed"),
                            component: "wallet", operation: "prepare_multisig", context: ["chain": "tron"])
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                notice = .walletUnavailable; preparing = false; task = nil
            }
        }
    }
    private func prepareSolanaKey(at index: Int) {
        guard slots.indices.contains(index), working == nil, !preparing else { return }
        let slot = slots[index], token = generation, operationID = UUID()
        working = slot.id; slots[index].notice = nil; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) { () throws -> BackupWallet.SolanaMultisig.Signer in
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("solana") {
                        try Task.checkCancellation()
                        switch slot.source {
                        case .fresh:
                            return try .phrase(OathWalletEngine.create().mnemonic, passphrase: nil)
                        case .phrase:
                            return try .phrase(slot.input, passphrase: slot.passphrase.isEmpty ? nil : RecoveryPassphrase.normalized(slot.passphrase))
                        case .wif:
                            let text = slot.input.trimmingCharacters(in: .whitespacesAndNewlines)
                            let key = try SolanaMultisigCrypto.importSigner(text)
                            return try .init(address: SolanaSendCrypto.address(privateKey: key), key: key)
                        }
                    }
                }
            }
            do {
                let key = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index), slots[index].id == slot.id else { return }
                if slots.contains(where: { $0.solanaMaterial?.address == key.address }) {
                    slots[index].notice = .multisigDuplicateKey
                } else {
                    slots[index].solanaMaterial = key; slots[index].input = ""; slots[index].passphrase = ""
                }
            } catch {
                // Imported key validation and cancellation are expected form outcomes.
                if slot.source == .fresh, !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(DiagnosticFailure("multisig_key_generation_failed"),
                            component: "wallet", operation: "create_multisig_key", context: ["chain": "solana"])
                    }
                }
                guard generation == token, !Task.isCancelled, slots.indices.contains(index) else { return }
                slots[index].notice = error is RecoveryPassphraseError ? .passphraseInvalid : slot.source == .fresh ? .walletUnavailable : slot.source == .wif ? .privateKeyInvalid : .scannerInvalidRecovery
            }
            guard generation == token else { return }
            working = nil; task = nil
        }
    }
    func finishSolana(_ onReady: @escaping (BackupWallet.SolanaMultisig) -> Void) {
        guard chain == .solana, ready else { return }
        let signers = slots.compactMap(\.solanaMaterial), required = required, token = generation, operationID = UUID()
        preparing = true; notice = nil
        task = Task {
            let work = Task.detached(priority: .userInitiated) {
                try OathDiagnostics.$operationID.withValue(operationID) {
                    try OathDiagnostics.$chain.withValue("solana") {
                        try Task.checkCancellation()
                        let bootstrap = try BackupWallet.SolanaMultisig.Signer.phrase(OathWalletEngine.create().mnemonic, passphrase: nil)
                        var key = try bootstrap.signingKey(); defer { key.resetBytes(in: 0..<key.count) }
                        let policy = try SolanaMultisigPolicy(createKey: bootstrap.address, required: required, members: signers.map(\.address))
                        let material = BackupWallet.SolanaMultisig(required: required, createSeed: key, address: try policy.vault, signers: signers)
                        try material.validateMaterial()
                        return material
                    }
                }
            }
            do {
                let material = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled else { return }
                preparing = false; task = nil; onReady(material)
            } catch {
                if !(error is CancellationError) {
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(DiagnosticFailure("multisig_policy_validation_failed"),
                            component: "wallet", operation: "prepare_multisig", context: ["chain": "solana"])
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                notice = .walletUnavailable; preparing = false; task = nil
            }
        }
    }
    func clear() {
        generation = UUID(); task?.cancel(); task = nil; working = nil; preparing = false
        slots = [Slot(), Slot(), Slot()]; required = 2; notice = nil
    }
}

struct OathMultisigChainScreen: View {
    let onBitcoin: () -> Void
    var onLitecoin: () -> Void = {}
    var onDogecoin: () -> Void = {}
    var onBitcoinCash: () -> Void = {}
    var onTron: () -> Void = {}
    var onSolana: () -> Void = {}
    var onEVM: () -> Void = {}
    var onTon: () -> Void = {}
    var onThorchain: () -> Void = {}
    var onNear: () -> Void = {}
    var onSui: () -> Void = {}
    var onAptos: () -> Void = {}
    var onStellar: () -> Void = {}
    var onXrpl: () -> Void = {}
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(strings.text(.chains))
                    .oathFont(.footnote, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                OathButton(action: onBitcoin) {
                    OathSettingsRow(title: strings.invariant("Bitcoin"), icon: "bitcoinsign",
                        networkLogo: OathImportChain.bitcoin.logoAsset)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("multisig.chain.bitcoin")
                OathButton(action: onLitecoin) {
                    OathSettingsRow(title: strings.invariant("Litecoin"), icon: "network",
                        networkLogo: OathImportChain.litecoin.logoAsset)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("multisig.chain.litecoin")
                OathButton(action: onBitcoinCash) {
                    OathSettingsRow(title: strings.invariant("Bitcoin Cash"), icon: "network",
                        networkLogo: OathImportChain.bitcoincash.logoAsset)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("multisig.chain.bitcoincash")
                OathButton(action: onDogecoin) {
                    OathSettingsRow(title: strings.invariant("Dogecoin"), icon: "network",
                        networkLogo: OathImportChain.dogecoin.logoAsset)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("multisig.chain.dogecoin")
                OathButton(action: onTron) {
                    OathSettingsRow(title: strings.invariant("TRON"), icon: "network",
                        networkLogo: OathImportChain.tron.logoAsset)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("multisig.chain.tron")
                OathButton(action: onSolana) {
                    OathSettingsRow(title: strings.invariant("Solana"), icon: "network",
                        networkLogo: OathImportChain.solana.logoAsset)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("multisig.chain.solana")
                OathButton(action: onEVM) {
                    OathSettingsRow(title: strings.invariant("Ethereum & EVM"), icon: "network",
                        networkLogo: OathImportChain.ethereum.logoAsset)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("multisig.chain.evm")
                OathButton(action: onTon) {
                    OathSettingsRow(title: strings.invariant("Gram"), icon: "network",
                        networkLogo: OathImportChain.ton.logoAsset)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("multisig.chain.ton")
                OathButton(action: onThorchain) {
                    OathSettingsRow(title: strings.invariant("THORChain"), icon: "network",
                        networkLogo: OathImportChain.thorchain.logoAsset)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("multisig.chain.thorchain")
                OathButton(action: onNear) {
                    OathSettingsRow(title: strings.invariant("NEAR"), icon: "network",
                        networkLogo: OathImportChain.near.logoAsset)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("multisig.chain.near")
                OathButton(action: onSui) {
                    OathSettingsRow(title: strings.invariant("Sui"), icon: "network",
                        networkLogo: OathImportChain.sui.logoAsset)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("multisig.chain.sui")
                OathButton(action: onAptos) {
                    OathSettingsRow(title: strings.invariant("Aptos"), icon: "network",
                        networkLogo: OathImportChain.aptos.logoAsset)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("multisig.chain.aptos")
                OathButton(action: onStellar) {
                    OathSettingsRow(title: strings.invariant("Stellar"), icon: "network",
                        networkLogo: OathImportChain.stellar.logoAsset)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("multisig.chain.stellar")
                OathButton(action: onXrpl) {
                    OathSettingsRow(title: strings.invariant("XRP"), icon: "network",
                        networkLogo: OathImportChain.xrpl.logoAsset)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("multisig.chain.xrpl")
            }
            .frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .toolbarBackground(Color(uiColor: OathSurfaceColors.canvas), for: .navigationBar)
        .navigationTitle(strings.text(.chooseChain)).navigationBarTitleDisplayMode(.inline)
        .oathNativeLocalization()
    }
}

struct OathMultisigSetupScreen: View {
    @Bindable var draft: OathMultisigDraft
    let onReady: (BackupWallet.BitcoinMultisig) -> Void
    var onTronReady: (BackupWallet.TronMultisig) -> Void = { _ in }
    var onEVMReady: (BackupWallet.EVMMultisig) -> Void = { _ in }
    var onTonReady: (BackupWallet.TonMultisig) -> Void = { _ in }
    var onThorchainReady: (BackupWallet.ThorchainMultisig) -> Void = { _ in }
    var onNearReady: (BackupWallet.NearMultisig) -> Void = { _ in }
    var onSuiReady: (BackupWallet.SuiMultisig) -> Void = { _ in }
    var onAptosReady: (BackupWallet.AptosMultisig) -> Void = { _ in }
    var onStellarReady: (BackupWallet.StellarMultisig) -> Void = { _ in }
    var onXrplReady: (BackupWallet.XrplMultisig) -> Void = { _ in }
    var onSolanaReady: (BackupWallet.SolanaMultisig) -> Void = { _ in }
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focusedInput: String?
    private var busy: Bool { draft.working != nil || draft.preparing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                policySection
                ForEach(Array(draft.slots.enumerated()), id: \.element.id) { index, slot in
                    OathSettingsSectionRule()
                    keySection(index: index, slot: slot)
                }
                if let notice = draft.notice {
                    Text(strings.text(notice))
                        .oathFont(.footnote).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(24)
                        .accessibilityIdentifier("multisig.notice")
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .toolbarBackground(Color(uiColor: OathSurfaceColors.canvas), for: .navigationBar)
        .navigationTitle(strings.text(.createMultisignatureWallet)).navigationBarTitleDisplayMode(.inline)
        .oathNativeLocalization()
        .toolbar {
            OathToolbarAction(title: .createWallet, isEnabled: draft.ready && scenePhase == .active,
                isWorking: draft.preparing, identifier: "multisig.create") {
                    focusedInput = nil
                    if draft.chain == .evm { draft.finishEVM(onEVMReady) }
                    else if draft.chain == .ton { draft.finishTon(onTonReady) }
                    else if draft.chain == .thorchain { draft.finishThorchain(onThorchainReady) }
                    else if draft.chain == .near { draft.finishNear(onNearReady) }
                    else if draft.chain == .sui { draft.finishSui(onSuiReady) }
                    else if draft.chain == .aptos { draft.finishAptos(onAptosReady) }
                    else if draft.chain == .stellar { draft.finishStellar(onStellarReady) }
                    else if draft.chain == .xrpl { draft.finishXrpl(onXrplReady) }
                    else if draft.chain == .solana { draft.finishSolana(onSolanaReady) }
                    else if draft.chain == .tron { draft.finishTron(onTronReady) }
                    else { draft.finish(onReady) }
                }
        }
        .overlay { if scenePhase != .active { Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { focusedInput = nil } }
        .onDisappear { focusedInput = nil }
        .oathErrorFeedback(draft.notice)
        .accessibilityIdentifier("multisig.setup")
    }

    private var policySection: some View {
        VStack(spacing: 0) {
            countMenu(title: .multisigTotalKeys, icon: "key.horizontal", value: draft.slots.count,
                      range: 2...draft.maximumKeys, identifier: "multisig.keyCount") { count in
                draft.resize(count)
            }
            countMenu(title: .multisigRequired, icon: "signature", value: draft.required,
                      range: 1...draft.slots.count, identifier: "multisig.required") { count in
                draft.required = count
            }
            OathSettingsFooter { Text(strings.text(.multisigLocalKeys)) }
        }
    }

    private func countMenu(title: OathStringKey, icon: String, value: Int,
                           range: ClosedRange<Int>, identifier: String,
                           select: @escaping (Int) -> Void) -> some View {
        Menu {
            Picker(strings.text(title), selection: Binding(get: { value }, set: { count in
                guard !busy, scenePhase == .active, range.contains(count) else { return }
                focusedInput = nil
                OathHaptics.shared.play(.selection)
                select(count)
            })) {
                ForEach(Array(range), id: \.self) { count in
                    Text(strings.number(count)).tag(count)
                }
            }
        } label: {
            OathSettingsRow(title: strings.text(title), icon: icon, value: strings.number(value))
        }
        .buttonStyle(OathSettingsRowButtonStyle())
        .oathNeutralControl()
        .disabled(busy)
        .accessibilityIdentifier(identifier)
    }

    private func keySection(index: Int, slot: OathMultisigDraft.Slot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if slot.isReady {
                HStack(spacing: 0) {
                    OathSettingsRow(title: keyTitle(index), icon: "key.horizontal", isSelected: true,
                        accessory: .none, subtitle: strings.text(.multisigKeyReady))
                    OathButton(strings.text(.clear), feedback: .clear) {
                        guard !busy, scenePhase == .active else { return }
                        focusedInput = nil
                        draft.changeSource(slot.source, at: index)
                    }
                    .buttonStyle(.plain)
                    .oathFont(.subheadline, weight: .semibold)
                    .oathNeutralControl()
                    .frame(minWidth: 44, minHeight: 44)
                    .padding(.trailing, 24)
                    .disabled(busy)
                    .accessibilityIdentifier("multisig.key.\(index + 1).clear")
                }
            } else {
                Text(keyTitle(index))
                    .oathFont(.footnote, weight: .semibold).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                sourceMenu(index: index, slot: slot)
                VStack(alignment: .leading, spacing: 16) {
                    if slot.source != .fresh {
                        OathPasteInput(hasText: !slot.input.isEmpty,
                            identifier: "multisig.key.\(index + 1).paste",
                            clearIdentifier: "multisig.key.\(index + 1).clearInput", onPaste: {
                                guard !busy, scenePhase == .active,
                                      let value = OathClipboard.paste() else { return }
                                inputBinding(index: index, passphrase: false).wrappedValue = value
                                focusedInput = focusID(index: index, passphrase: false)
                            }, onClear: {
                                guard !busy, scenePhase == .active else { return }
                                inputBinding(index: index, passphrase: false).wrappedValue = ""
                                focusedInput = focusID(index: index, passphrase: false)
                            }) {
                                secureInput(index: index, passphrase: false)
                            }
                            .disabled(busy)
                        if slot.source == .phrase {
                            secureInput(index: index, passphrase: true).oathSettingsField()
                        } else {
                            Text(strings.text(draft.chain == .ton ? .multisigTonKeyDetail : draft.chain == .thorchain ? .multisigThorchainKeyDetail : draft.chain == .near ? .multisigNearKeyDetail : draft.chain == .sui ? .multisigSuiKeyDetail : draft.chain == .aptos ? .multisigAptosKeyDetail : draft.chain == .stellar ? .multisigStellarKeyDetail : draft.chain == .xrpl ? .multisigXrplKeyDetail : draft.chain == .solana ? .multisigSolanaKeyDetail : draft.chain == .evm ? .multisigEVMKeyDetail : draft.chain == .tron ? .multisigTronKeyDetail : draft.chain == .dogecoin ? .multisigDogecoinWIFDetail : draft.chain == .bitcoincash ? .multisigBitcoinCashWIFDetail : draft.chain == .litecoin ? .multisigLitecoinWIFDetail : .multisigWIFDetail))
                                .oathFont(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let notice = slot.notice {
                        Text(strings.text(notice)).oathFont(.footnote).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("multisig.key.\(index + 1).notice")
                    }
                    OathActionButton(title: strings.text(slot.source == .fresh ? .multisigCreateKey : .importAction),
                        isWorking: draft.working == slot.id) { prepareKey(index) }
                        .disabled(busy || (slot.source != .fresh && slot.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .accessibilityIdentifier("multisig.key.\(index + 1).prepare")
                        .oathActionArea(existingInset: 24)
                }
                .padding(.horizontal, 24).padding(.bottom, 12)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: slot.isReady)
        .oathErrorFeedback(slot.notice)
        .accessibilityElement(children: .contain)
    }

    private func sourceMenu(index: Int, slot: OathMultisigDraft.Slot) -> some View {
        Menu {
            Picker(strings.text(.multisigKeySource), selection: Binding(get: { slot.source }, set: { source in
                guard !busy, scenePhase == .active, source != slot.source else { return }
                focusedInput = nil
                OathHaptics.shared.play(.selection)
                draft.changeSource(source, at: index)
            })) {
                ForEach(OathMultisigDraft.Source.allCases) { source in
                    Text(strings.text(sourceTitle(source))).tag(source)
                }
            }
        } label: {
            OathSettingsRow(title: strings.text(.multisigKeySource), icon: sourceIcon(slot.source),
                subtitle: strings.text(sourceTitle(slot.source)))
        }
        .buttonStyle(OathSettingsRowButtonStyle())
        .oathNeutralControl()
        .disabled(busy)
        .accessibilityLabel(strings.text(.multisigKeySource))
        .accessibilityValue(strings.text(sourceTitle(slot.source)))
        .accessibilityIdentifier("multisig.key.\(index + 1).source")
    }

    private func keyTitle(_ index: Int) -> String {
        strings.format(.multisigKeyNumber, strings.number(index + 1))
    }

    private func sourceTitle(_ source: OathMultisigDraft.Source) -> OathStringKey {
        switch source {
        case .fresh: .multisigCreateKey
        case .wif: .privateKeyInput
        case .phrase: .recoveryPhrase
        }
    }

    private func sourceIcon(_ source: OathMultisigDraft.Source) -> String {
        switch source {
        case .fresh: "plus.circle"
        case .wif: "key.horizontal"
        case .phrase: "text.alignleft"
        }
    }

    private func prepareKey(_ index: Int) {
        guard !busy, scenePhase == .active else { return }
        focusedInput = nil
        draft.prepareKey(at: index)
    }

    private func focusID(index: Int, passphrase: Bool) -> String {
        "\(index)-\(passphrase)"
    }

    private func inputBinding(index: Int, passphrase: Bool) -> Binding<String> {
        Binding(get: {
            guard draft.slots.indices.contains(index) else { return "" }
            return passphrase ? draft.slots[index].passphrase : draft.slots[index].input
        }, set: { value in
            guard !busy, draft.slots.indices.contains(index),
                  value.utf8.count <= (passphrase ? 1024 : 16384) else { return }
            if passphrase { draft.slots[index].passphrase = value } else { draft.slots[index].input = value }
            draft.slots[index].notice = nil
            draft.notice = nil
        })
    }

    private func secureInput(index: Int, passphrase: Bool) -> some View {
        let source = draft.slots.indices.contains(index) ? draft.slots[index].source : .fresh
        let fieldID = focusID(index: index, passphrase: passphrase)
        return OathSecureInput(text: inputBinding(index: index, passphrase: passphrase),
            title: strings.text(passphrase ? .multisigOptionalPassphrase : source == .wif ? .privateKeyInput : .recoveryPhrase),
            identifier: "multisig.key.\(index + 1)." + (passphrase ? "passphrase" : "input"),
            returnKey: source == .phrase && !passphrase ? .next : .done,
            wantsFocus: !busy && scenePhase == .active && focusedInput == fieldID,
            resignsFocus: busy || scenePhase != .active || focusedInput != fieldID,
            onFocus: { focusedInput = fieldID },
            onDismissKeyboard: { focusedInput = nil },
            onSubmit: {
                if source == .phrase && !passphrase {
                    focusedInput = focusID(index: index, passphrase: true)
                } else { prepareKey(index) }
            }, minimumPasswordLength: nil)
        .disabled(busy)
    }
}

struct OathEVMMultisigNetworkScreen: View {
    let select: (EVMSendNetwork) -> Void
    @Environment(\.oathLocalizer) private var strings
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(EVMSendNetwork.allCases.filter { !$0.isTestnet }, id: \.self) { network in
                    if let chain = OathImportChain(rawValue: network.rawValue) {
                        OathButton { select(network) } label: {
                            OathSettingsRow(title: strings.invariant(chain.name), icon: "network", networkLogo: chain.logoAsset)
                        }.buttonStyle(OathSettingsRowButtonStyle())
                    }
                }
            }.frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .navigationTitle(strings.text(.chooseChain)).navigationBarTitleDisplayMode(.inline)
        .oathNativeLocalization()
    }
}
