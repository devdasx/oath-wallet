import Foundation

/// Keeps Bitcoin-family balances current while the wallet is visible.
///
/// Electrum status notifications act only as invalidations. Every event is
/// followed by a fresh `get_balance` read so confirmed and mempool amounts are
/// persisted atomically before the UI publishes its next snapshot.
actor BitcoinFamilyBalanceMonitorService {
    private struct HDStatusStream: Sendable {
        let scriptHash: String
        let stream: AsyncStream<JSONValue>
    }

    static let shared = BitcoinFamilyBalanceMonitorService()

    private let electrum = BitcoinFamilyElectrumClient.shared
    private let syncService = BitcoinFamilySyncService.shared
    private let silentPaymentSync = BitcoinSilentPaymentSyncService.shared

    func monitor(
        walletID: String,
        onProgress: WalletSyncProgressHandler? = nil
    ) async {
        do { try Task.checkCancellation() }
        catch { return }
        let usesMuunRecovery = (try? await MuunRecoveryWalletSyncService
            .shared.supports(walletID: walletID)) == true
        let usesBitcoinHD: Bool
        if usesMuunRecovery {
            usesBitcoinHD = false
        } else {
            usesBitcoinHD = (try? await BitcoinHDWalletSyncService.shared
                .supports(walletID: walletID)) == true
        }
        let supportsBitcoinSingleKey: Bool
        if usesMuunRecovery || usesBitcoinHD {
            supportsBitcoinSingleKey = false
        } else {
            supportsBitcoinSingleKey = (try? await BitcoinHDWalletSyncService
                .shared
                .supportsSingleKey(walletID: walletID)) == true
        }
        let usesBitcoinSingleKey = supportsBitcoinSingleKey
        let materials: [BitcoinFamilyAccountMaterial]
        do {
            materials = try await syncService.accountMaterials(
                walletID: walletID
            )
        } catch {
            return
        }

        await withTaskGroup(of: Void.self) { group in
            if usesMuunRecovery {
                group.addTask {
                    await self.monitorMuunRecovery(
                        walletID: walletID,
                        onProgress: onProgress
                    )
                }
            } else if usesBitcoinHD {
                group.addTask {
                    await self.monitorBitcoinHD(
                        walletID: walletID,
                        onProgress: onProgress
                    )
                }
            } else if usesBitcoinSingleKey {
                group.addTask {
                    await self.monitorBitcoinSingleKey(
                        walletID: walletID,
                        onProgress: onProgress
                    )
                }
            }
            for material in materials where !(usesMuunRecovery
                || usesBitcoinHD || usesBitcoinSingleKey)
                || material.chain != .bitcoin {
                group.addTask {
                    await self.monitor(
                        material: material,
                        walletID: walletID,
                        onProgress: onProgress
                    )
                }
            }
            await group.waitForAll()
        }
    }

    private func monitorMuunRecovery(
        walletID: String,
        onProgress: WalletSyncProgressHandler?
    ) async {
        var retryDelaySeconds: UInt64 = 1
        while !Task.isCancelled {
            do {
                try Task.checkCancellation()
                let initial = try await MuunRecoveryWalletSyncService.shared
                    .refreshBalanceSnapshot(
                        walletID: walletID,
                        onProgress: onProgress
                    )
                let initialHashes = Set(
                    initial.states.map(\.derived.scriptHash)
                )
                let streams = try await bitcoinHDStatusStreams(
                    scriptHashes: initialHashes
                )

                // Subscribe before the verification read. A payment arriving
                // during setup is included by that read or retained as a
                // status notification. A newly used V5 receive address changes
                // the hash set and immediately rebuilds the subscriptions.
                let verified = try await MuunRecoveryWalletSyncService.shared
                    .refreshBalanceSnapshot(
                        walletID: walletID,
                        onProgress: onProgress
                    )
                guard Set(verified.states.map(\.derived.scriptHash))
                        == initialHashes else {
                    retryDelaySeconds = 1
                    continue
                }

                retryDelaySeconds = 1
                try await waitForBitcoinAddressChange(streams)
            } catch is CancellationError {
                return
            } catch {
                do {
                    try await Task.sleep(
                        for: .seconds(retryDelaySeconds)
                    )
                } catch {
                    return
                }
                retryDelaySeconds = min(retryDelaySeconds * 2, 30)
            }
        }
    }

    private func monitorBitcoinSingleKey(
        walletID: String,
        onProgress: WalletSyncProgressHandler?
    ) async {
        var retryDelaySeconds: UInt64 = 1
        while !Task.isCancelled {
            do {
                try Task.checkCancellation()
                let initial = try await BitcoinHDWalletSyncService.shared
                    .refreshSingleKeyBalanceSnapshot(
                        walletID: walletID,
                        onProgress: onProgress
                    )
                let initialHashes = Set(
                    initial.states.map(\.derived.scriptHash)
                )
                let streams = try await bitcoinHDStatusStreams(
                    scriptHashes: initialHashes
                )
                let verified = try await BitcoinHDWalletSyncService.shared
                    .refreshSingleKeyBalanceSnapshot(
                        walletID: walletID,
                        onProgress: onProgress
                    )
                guard Set(verified.states.map(\.derived.scriptHash))
                        == initialHashes else {
                    retryDelaySeconds = 1
                    continue
                }
                retryDelaySeconds = 1
                try await waitForBitcoinAddressChange(streams)
            } catch is CancellationError {
                return
            } catch {
                do {
                    try await Task.sleep(for: .seconds(retryDelaySeconds))
                } catch {
                    return
                }
                retryDelaySeconds = min(retryDelaySeconds * 2, 30)
            }
        }
    }

    private func monitorBitcoinHD(
        walletID: String,
        onProgress: WalletSyncProgressHandler?
    ) async {
        var retryDelaySeconds: UInt64 = 1
        while !Task.isCancelled {
            do {
                try Task.checkCancellation()
                let initial = try await BitcoinHDWalletSyncService.shared
                    .refreshBalanceSnapshot(
                        walletID: walletID,
                        onProgress: onProgress
                    )
                let initialHashes = try await monitoredBitcoinScriptHashes(
                    walletID: walletID,
                    states: initial.states
                )
                let streams = try await bitcoinHDStatusStreams(
                    scriptHashes: initialHashes
                )

                // Subscriptions are active before this exact refresh. Any
                // transaction arriving during setup is therefore represented
                // by this read or by a queued status notification.
                let verified = try await BitcoinHDWalletSyncService.shared
                    .refreshBalanceSnapshot(
                        walletID: walletID,
                        onProgress: onProgress
                    )
                let verifiedHashes = try await monitoredBitcoinScriptHashes(
                    walletID: walletID,
                    states: verified.states
                )
                if verifiedHashes != initialHashes {
                    retryDelaySeconds = 1
                    continue
                }

                retryDelaySeconds = 1
                try await waitForBitcoinAddressChange(streams)
            } catch is CancellationError {
                return
            } catch {
                do {
                    try await Task.sleep(
                        for: .seconds(retryDelaySeconds)
                    )
                } catch {
                    return
                }
                retryDelaySeconds = min(retryDelaySeconds * 2, 30)
            }
        }
    }

    private func monitoredBitcoinScriptHashes(
        walletID: String,
        states: [BitcoinHDAddressState]
    ) async throws -> Set<String> {
        Set(states.map(\.derived.scriptHash)).union(
            try await silentPaymentSync.monitoredScriptHashes(
                walletID: walletID
            )
        )
    }

    private func bitcoinHDStatusStreams(
        scriptHashes: Set<String>, chain: BitcoinFamilyChain = .bitcoin
    ) async throws -> [HDStatusStream] {
        guard !scriptHashes.isEmpty else {
            throw BitcoinFamilyElectrumError.invalidResponse
        }
        return try await withThrowingTaskGroup(
            of: HDStatusStream.self
        ) { group in
            for scriptHash in scriptHashes {
                group.addTask {
                    HDStatusStream(
                        scriptHash: scriptHash,
                        stream: try await self.electrum.statusUpdates(
                            chain: chain,
                            scriptHash: scriptHash
                        )
                    )
                }
            }
            var values: [HDStatusStream] = []
            values.reserveCapacity(scriptHashes.count)
            while let value = try await group.next() {
                values.append(value)
            }
            return values.sorted { $0.scriptHash < $1.scriptHash }
        }
    }

    private func waitForBitcoinHDChange(
        _ streams: [HDStatusStream],
        silentUpdates: BitcoinSilentPaymentLiveSubscription
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in streams {
                group.addTask {
                    for await _ in value.stream {
                        try Task.checkCancellation()
                        return
                    }
                    throw BitcoinFamilyElectrumError.unavailable
                }
            }
            group.addTask {
                for try await _ in silentUpdates.updates {
                    try Task.checkCancellation()
                    return
                }
                throw BitcoinFamilyElectrumError.unavailable
            }
            guard try await group.next() != nil else {
                throw BitcoinFamilyElectrumError.unavailable
            }
            group.cancelAll()
        }
    }

    private func waitForBitcoinAddressChange(
        _ streams: [HDStatusStream]
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in streams {
                group.addTask {
                    for await _ in value.stream {
                        try Task.checkCancellation()
                        return
                    }
                    throw BitcoinFamilyElectrumError.unavailable
                }
            }
            guard try await group.next() != nil else {
                throw BitcoinFamilyElectrumError.unavailable
            }
            group.cancelAll()
        }
    }

    private func monitor(
        material: BitcoinFamilyAccountMaterial,
        walletID: String,
        onProgress: WalletSyncProgressHandler?
    ) async {
        var retryDelaySeconds: UInt64 = 1
        while !Task.isCancelled {
            do {
                try Task.checkCancellation()
                if material.chain.supportsFamilyHD,
                   try await BitcoinFamilyHDDiscoveryService.shared.supports(walletID: walletID, chain: material.chain) {
                    let scan = try await BitcoinFamilyHDDiscoveryService.shared.discover(walletID: walletID, chain: material.chain)
                    let hashes = Set(scan.states.map(\.derived.scriptHash))
                    let streams = try await bitcoinHDStatusStreams(scriptHashes: hashes, chain: material.chain)
                    let verified = try await BitcoinFamilyHDDiscoveryService.shared.discover(walletID: walletID, chain: material.chain)
                    await onProgress?(WalletSyncProgressEvent(source: .bitcoinFamily,
                        networkID: material.chain.networkID, stage: .balancesPersisted))
                    retryDelaySeconds = 1
                    guard Set(verified.states.map(\.derived.scriptHash)) == hashes else { continue }
                    try await waitForBitcoinAddressChange(streams)
                    continue
                }
                let stream = try await electrum.statusUpdates(
                    chain: material.chain,
                    scriptHash:
                        BitcoinFamilySyncService.electrumScriptHash(material)
                )

                // Subscribe first, then read. A transaction arriving during
                // setup either changes this exact read or produces an event.
                try await syncService.refreshBalance(
                    material: material,
                    walletID: walletID,
                    onProgress: onProgress
                )
                retryDelaySeconds = 1

                for await _ in stream {
                    try Task.checkCancellation()
                    try Task.checkCancellation()
                    try await syncService.refreshBalance(
                        material: material,
                        walletID: walletID,
                        onProgress: onProgress
                    )
                }
                try Task.checkCancellation()
                throw BitcoinFamilyElectrumError.unavailable
            } catch is CancellationError {
                return
            } catch {
                do {
                    try await Task.sleep(
                        for: .seconds(retryDelaySeconds)
                    )
                } catch {
                    return
                }
                retryDelaySeconds = min(retryDelaySeconds * 2, 30)
            }
        }
    }
}
