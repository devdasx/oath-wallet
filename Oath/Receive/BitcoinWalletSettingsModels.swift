import Foundation

struct BitcoinHDBranchStatistics: Hashable, Sendable {
    let branch: BitcoinHDAddressBranch
    let generatedCount: Int
    let usedCount: Int
    let reservedCount: Int
    let currentIndex: Int
    let balanceAtomic: BitcoinFamilyAtomicInteger
}

struct BitcoinHDTypeSettingsSnapshot: Hashable, Sendable {
    let descriptor: BitcoinHDAccountDescriptor
    let states: [BitcoinHDAddressState]
    let external: BitcoinHDBranchStatistics
    let change: BitcoinHDBranchStatistics

    var balanceAtomic: BitcoinFamilyAtomicInteger {
        external.balanceAtomic.adding(change.balanceAtomic)
    }

    var generatedCount: Int {
        external.generatedCount + change.generatedCount
    }

    var usedCount: Int {
        external.usedCount + change.usedCount
    }
}

struct BitcoinSilentPaymentSettingsSnapshot: Hashable, Sendable {
    let account: BitcoinSilentPaymentAccount?
    let outputs: [BitcoinSilentPaymentOutput]

    var balanceAtomic: BitcoinFamilyAtomicInteger {
        outputs.lazy.filter { !$0.isSpent }.reduce(.zero) {
            $0.adding($1.valueAtomic)
        }
    }

    var unspentCount: Int {
        outputs.lazy.filter { !$0.isSpent }.count
    }
}

struct BitcoinWalletSettingsSnapshot: Hashable, Sendable {
    let selectedType: BitcoinHDAddressType
    let usesSilentPayments: Bool
    let types: [BitcoinHDTypeSettingsSnapshot]
    let silentPayments: BitcoinSilentPaymentSettingsSnapshot

    var balanceAtomic: BitcoinFamilyAtomicInteger {
        types.reduce(silentPayments.balanceAtomic) {
            $0.adding($1.balanceAtomic)
        }
    }

    var generatedAddressCount: Int {
        types.reduce(0) { $0 + $1.generatedCount }
    }
}

struct BitcoinWalletSettingsRepository: Sendable {
    let database: WalletDatabase

    func load(walletID: String) async throws
        -> BitcoinWalletSettingsSnapshot {
        async let descriptorsValue = database.bitcoinHDAccountDescriptors(
            walletID: walletID
        )
        async let statesValue = database.bitcoinHDAddresses(
            walletID: walletID
        )
        async let selectedTypeValue = database.bitcoinReceiveAddressType(
            walletID: walletID
        )
        async let silentEnabledValue = database.bitcoinUsesSilentPayments(
            walletID: walletID
        )
        async let silentAccountValue = database.bitcoinSilentPaymentAccount(
            walletID: walletID
        )
        async let silentOutputsValue = database.bitcoinSilentPaymentOutputs(
            walletID: walletID
        )
        let (
            descriptors, states, selectedType, silentEnabled,
            silentAccount, silentOutputs
        ) = try await (
            descriptorsValue, statesValue, selectedTypeValue,
            silentEnabledValue, silentAccountValue, silentOutputsValue
        )

        var typeSnapshots: [BitcoinHDTypeSettingsSnapshot] = []
        typeSnapshots.reserveCapacity(descriptors.count)
        for type in BitcoinHDAddressType.allCases {
            guard let descriptor = descriptors.first(where: {
                $0.addressType == type
            }) else { continue }
            let typeStates = states.filter {
                $0.derived.addressType == type
            }
            async let externalPreferred = database
                .bitcoinHDPreferredAddressIndex(
                    walletID: walletID,
                    addressType: type,
                    branch: .external
                )
            async let changePreferred = database
                .bitcoinHDPreferredAddressIndex(
                    walletID: walletID,
                    addressType: type,
                    branch: .change
                )
            let (externalIndex, changeIndex) = try await (
                externalPreferred, changePreferred
            )
            typeSnapshots.append(
                BitcoinHDTypeSettingsSnapshot(
                    descriptor: descriptor,
                    states: typeStates,
                    external: Self.statistics(
                        branch: .external,
                        states: typeStates,
                        preferredIndex: externalIndex
                    ),
                    change: Self.statistics(
                        branch: .change,
                        states: typeStates,
                        preferredIndex: changeIndex
                    )
                )
            )
        }
        return BitcoinWalletSettingsSnapshot(
            selectedType: selectedType,
            usesSilentPayments: silentEnabled,
            types: typeSnapshots,
            silentPayments: BitcoinSilentPaymentSettingsSnapshot(
                account: silentAccount,
                outputs: silentOutputs
            )
        )
    }

    private static func statistics(
        branch: BitcoinHDAddressBranch,
        states: [BitcoinHDAddressState],
        preferredIndex: Int?
    ) -> BitcoinHDBranchStatistics {
        let branchStates = states.filter { $0.derived.branch == branch }
        let unavailable = branchStates.filter {
            $0.isUsed || $0.isReserved
        }
        let automaticIndex = (unavailable.map(\.derived.index).max() ?? -1)
            + 1
        return BitcoinHDBranchStatistics(
            branch: branch,
            generatedCount: branchStates.count,
            usedCount: branchStates.lazy.filter(\.isUsed).count,
            reservedCount: branchStates.lazy.filter(\.isReserved).count,
            currentIndex: preferredIndex ?? automaticIndex,
            balanceAtomic: branchStates.reduce(.zero) {
                $0.adding($1.balanceAtomic)
            }
        )
    }
}

extension BitcoinFamilyAtomicInteger {
    var bitcoinSettingsDisplay: String {
        let units = (try? userUnits(decimals: 8)) ?? decimalText
        return "\(units) BTC"
    }
}
