import XCTest
import Foundation
import GRDB
import WalletCore

final class FamilyHDTests: XCTestCase {
    // Published BIP39 test vector. Never use this seed to hold funds.
    let credential = WalletRecoveryCredential(mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
    let chains: [BitcoinFamilyChain] = [.dogecoin, .litecoin, .bitcoinCash]

    func testPublicChildMatchesPrivateChildAcrossChainsFormatsBranchesAndBoundary() throws {
        var addresses = Set<String>()
        var vectors: [[String: Any]] = []
        for chain in chains {
            for descriptor in try BitcoinFamilyHDDerivation.descriptors(credential: credential, chain: chain) {
                for branch in [BitcoinHDAddressBranch.external, .change] {
                    for index in [0, 1, 4, 5, 19, 20, 100, 2_147_483_647] {
                        let child = try BitcoinFamilyHDDerivation.address(descriptor: descriptor, branch: branch, index: index)
                        let key = try BitcoinFamilyHDDerivation.privateKey(credential: credential, chain: chain, owner: child)
                        XCTAssertEqual(key.getPublicKeySecp256k1(compressed: true).data, child.publicKey)
                        XCTAssertTrue(addresses.insert(child.address).inserted)
                        vectors.append(["chain": chain.rawValue, "path": child.derivationPath, "address": child.address,
                                        "script": child.scriptPubKey.hexString, "publicKey": child.publicKey.hexString])
                    }
                }
                XCTAssertThrowsError(try BitcoinFamilyHDDerivation.address(descriptor: descriptor, branch: .external, index: -1))
                XCTAssertThrowsError(try BitcoinFamilyHDDerivation.address(descriptor: descriptor, branch: .external, index: 2_147_483_648))
            }
        }
        XCTAssertEqual(vectors.count, 80)
        try JSONSerialization.data(withJSONObject: vectors, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "aperture-family-hd/derived-vectors.json"))
    }

    func testGapFiveExtendsAtBoundaryAndHonorsPersistedHighWater() async throws {
        let empty = try await HDGapDiscovery.scan(gapLimit: 5, highestKnownUsedIndex: -1) { range in
            range.map { HDGapDiscovery.Observation(index: $0, isUsed: false, value: $0) }
        }
        XCTAssertEqual(empty, Array(0..<5))
        let extended = try await HDGapDiscovery.scan(gapLimit: 5, highestKnownUsedIndex: -1) { range in
            range.map { HDGapDiscovery.Observation(index: $0, isUsed: [4, 9].contains($0), value: $0) }
        }
        XCTAssertEqual(extended, Array(0..<15))
        let remembered = try await HDGapDiscovery.scan(gapLimit: 5, highestKnownUsedIndex: 20) { range in
            range.map { HDGapDiscovery.Observation(index: $0, isUsed: false, value: $0) }
        }
        XCTAssertEqual(remembered, Array(0..<26))
    }

    func testIncompleteBatchAndScanLimitFailClosed() async throws {
        do {
            _ = try await HDGapDiscovery.scan(gapLimit: 5, highestKnownUsedIndex: -1) { _ in
                [HDGapDiscovery.Observation(index: 0, isUsed: false, value: 0)]
            }
            XCTFail("A partial provider batch must never become an empty balance")
        } catch HDGapDiscovery.Failure.invalidWindow { }
        do {
            _ = try await HDGapDiscovery.scan(gapLimit: 5, highestKnownUsedIndex: -1, maximumAddressCount: 10) { range in
                range.map { HDGapDiscovery.Observation(index: $0, isUsed: true, value: $0) }
            }
            XCTFail("A truncated scan must report failure")
        } catch HDGapDiscovery.Failure.scanLimitReached { }
        do {
            _ = try await HDGapDiscovery.scan(gapLimit: 5, highestKnownUsedIndex: Int.max) { range in
                range.map { HDGapDiscovery.Observation(index: $0, isUsed: false, value: $0) }
            }
            XCTFail("Invalid high-water mark")
        } catch HDGapDiscovery.Failure.invalidWindow { }
    }

    func testConcurrentChangeReservationsAreUniqueAndChainIsolated() async throws {
        let database = try WalletDatabase(credential: credential)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for chain in chains { group.addTask { _ = try await database.ensureBitcoinFamilyHDWallet(walletID: "fixture", chain: chain) } }
            try await group.waitForAll()
        }
        for chain in chains {
            let initial = try await database.bitcoinFamilyHDAddresses(walletID: "fixture", chain: chain)
            XCTAssertEqual(initial.count, chain.familyHDTypes.count * 10)
            let reserved = try await withThrowingTaskGroup(of: BitcoinHDDerivedAddress.self) { group in
                for _ in 0..<12 {
                    group.addTask { try await database.freshBitcoinFamilyHDAddress(walletID: "fixture", chain: chain, branch: .change, reserve: true) }
                }
                var values: [BitcoinHDDerivedAddress] = []
                for try await child in group { values.append(child) }
                return values
            }
            XCTAssertEqual(Set(reserved.map(\.index)), Set(0..<12))
            XCTAssertEqual(Set(reserved.map(\.address)).count, 12)
            let receive = try await database.freshBitcoinFamilyHDAddress(walletID: "fixture", chain: chain)
            XCTAssertEqual(receive.index, 0)
            let last = try XCTUnwrap(reserved.first { $0.index == 11 })
            try await database.releaseBitcoinFamilyHDChange(walletID: "fixture", chain: chain, address: last.address)
            let reused = try await database.freshBitcoinFamilyHDAddress(walletID: "fixture", chain: chain, branch: .change, reserve: true)
            XCTAssertEqual(reused, last)
        }
        try await database.pool.write { try $0.execute(sql: "DELETE FROM wallets WHERE id = 'fixture'") }
        for chain in chains {
            let states = try await database.bitcoinFamilyHDAddresses(walletID: "fixture", chain: chain)
            XCTAssertTrue(states.isEmpty)
        }
    }

    func testOfflineMultiAddressSigningAndMixedLitecoinScripts() throws {
        var signedFixtures: [[String: Any]] = []
        for chain in chains {
            let descriptors = try BitcoinFamilyHDDerivation.descriptors(credential: credential, chain: chain)
            let owners = try descriptors.flatMap { descriptor in
                try [BitcoinHDAddressBranch.external, .change].map {
                    try BitcoinFamilyHDDerivation.address(descriptor: descriptor, branch: $0, index: 4)
                }
            }
            let outputs = owners.enumerated().map { offset, owner in
                SendBitcoinUTXO(networkID: chain.networkID,
                    outpoint: SendBitcoinOutpoint(transactionHash: String(repeating: String(format: "%02x", offset + 1), count: 32), outputIndex: offset),
                    valueAtomic: "100000000", blockHeight: 1, confirmations: 1, owner: owner)
            }
            let primary = try XCTUnwrap(descriptors.first { $0.type == chain.familyHDDefaultType })
            let change = try BitcoinFamilyHDDerivation.address(descriptor: primary, branch: .change, index: 8)
            let recipient = try BitcoinFamilyHDDerivation.address(descriptor: primary, branch: .external, index: 9)
            let rate: Int64 = chain == .dogecoin ? 1000 : 10
            let fee = SendResolvedNetworkFee(model: .satoshiPerByte, primaryValue: String(rate), secondaryValue: nil)
            let options = SendBitcoinFamilyOptions(coinSelection: .manual(outputs), replaceByFee: true)
            for maximum in [false, true] {
                let draft = SendDraft(usesMaximumBalance: maximum)
                let review = try SendBitcoinFamilyHDTransactionSigner.selectionPlan(draft: draft, chain: chain, outputs: outputs,
                    requestedAtomic: 50_000_000, byteFee: rate, fee: fee, options: options,
                    changeAddress: change.address, recipientAddress: recipient.address)
                let signed = try SendBitcoinFamilyHDTransactionSigner.sign(draft: draft,
                    material: SendResolvedSigningMaterial(bitcoinHDRecoveryCredential: credential), chain: chain, outputs: outputs,
                    requestedAtomic: 50_000_000, byteFee: rate, fee: fee, options: options,
                    changeAddress: change.address, recipientAddress: recipient.address)
                XCTAssertEqual(signed.feeAtomic, review.feeAtomic)
                XCTAssertEqual(signed.amountAtomic, review.recipientAmountAtomic)
                XCTAssertEqual(signed.spentOutpointIDs, Set(outputs.map(\.id)))
                XCTAssertEqual(signed.changeAddress == nil, maximum)
                signedFixtures.append(["chain": chain.rawValue, "hex": signed.encoded.hexString, "txid": signed.transactionID,
                    "fee": signed.feeAtomic, "rate": rate, "amount": signed.amountAtomic,
                    "inputs": outputs.map { ["outpoint": $0.id, "value": $0.valueAtomic,
                        "script": $0.owner!.scriptPubKey.hexString, "publicKey": $0.owner!.publicKey.hexString] }])
            }
        }
        try JSONSerialization.data(withJSONObject: signedFixtures, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "aperture-family-hd/signed-fixtures.json"))
    }

    func testDiscoveryChecksUsedEmptyAddressesAndBothBranchesInParallel() async throws {
        let database = try WalletDatabase(credential: credential)
        var known: [String: BitcoinHDDerivedAddress] = [:]
        for chain in chains {
            for descriptor in try BitcoinFamilyHDDerivation.descriptors(credential: credential, chain: chain) {
                for branch in [BitcoinHDAddressBranch.external, .change] {
                    for index in 0..<15 {
                        let child = try BitcoinFamilyHDDerivation.address(descriptor: descriptor, branch: branch, index: index)
                        known[child.scriptHash] = child
                    }
                }
            }
        }
        let children = known
        let activity = RequestActivity()
        let client = BitcoinFamilyElectrumClient { chain, method, hash in
            await activity.start(chain: chain)
            try await Task.sleep(nanoseconds: 1_000_000)
            await activity.end()
            let child = try XCTUnwrap(children[hash])
            if method == "blockchain.scripthash.get_balance" {
                let funded = child.index == 8 && child.branch == .change
                return .object(["confirmed": .string(funded ? "300" : "0"), "unconfirmed": .string("0")])
            }
            return [4, 8].contains(child.index) ? .array([.object([
                "tx_hash": .string(String(repeating: "ab", count: 32)), "height": .string("123")])]) : .array([])
        }
        let service = BitcoinFamilyHDDiscoveryService(database: database, electrum: client)
        let results = try await withThrowingTaskGroup(of: (BitcoinFamilyChain, BitcoinFamilyHDDiscoveryResult).self) { group in
            for chain in chains { group.addTask { (chain, try await service.discover(walletID: "fixture", chain: chain)) } }
            var values: [(BitcoinFamilyChain, BitcoinFamilyHDDiscoveryResult)] = []
            for try await value in group { values.append(value) }
            return values
        }
        for (chain, result) in results {
            XCTAssertEqual(result.balance.decimalText, String(300 * chain.familyHDTypes.count))
            XCTAssertEqual(result.states.count, 28 * chain.familyHDTypes.count)
            XCTAssertEqual(result.transactions.count, 1, "Deduplicate one transfer seen on several owned addresses")
            XCTAssertEqual(result.receiveAddress.index, 9)
            XCTAssertTrue(result.states.contains { $0.derived.index == 4 && $0.isUsed && $0.balanceAtomic.isZero })
        }
        let overlap = await activity.snapshot()
        XCTAssertGreaterThan(overlap.maximum, 1)
        XCTAssertEqual(overlap.chains, Set(chains))

        let failing = BitcoinFamilyElectrumClient { _, method, _ in
            if method == "blockchain.scripthash.get_history" { throw BitcoinFamilyElectrumError.unavailable }
            return .object(["confirmed": .string("0"), "unconfirmed": .string("0")])
        }
        do {
            _ = try await BitcoinFamilyHDDiscoveryService(database: database, electrum: failing)
                .discover(walletID: "fixture", chain: .dogecoin)
            XCTFail("Provider failure must not publish a partial zero balance")
        } catch { }
        let preserved = try await database.pool.read {
            try String.fetchOne($0, sql: "SELECT balance FROM publishedBalances WHERE networkID = 'dogecoin'")
        }
        XCTAssertEqual(preserved, "300")
    }

    func testDifferentServiceInstancesCoalesceTheSameWalletScan() async throws {
        let database = try WalletDatabase(credential: credential)
        _ = try await database.ensureBitcoinFamilyHDWallet(walletID: "fixture", chain: .dogecoin)
        let activity = RequestActivity()
        let client = BitcoinFamilyElectrumClient { chain, method, _ in
            await activity.start(chain: chain)
            try await Task.sleep(nanoseconds: 20_000_000)
            await activity.end()
            return method.hasSuffix("get_balance")
                ? .object(["confirmed": .string("0"), "unconfirmed": .string("0")]) : .array([])
        }
        async let first = BitcoinFamilyHDDiscoveryService(database: database, electrum: client).discover(walletID: "fixture", chain: .dogecoin)
        async let second = BitcoinFamilyHDDiscoveryService(database: database, electrum: client).discover(walletID: "fixture", chain: .dogecoin)
        let (one, two) = try await (first, second)
        XCTAssertEqual(one.states, two.states)
        let requests = await activity.snapshot()
        XCTAssertEqual(requests.count, 20, "Two branches × five addresses × balance/history, once")
    }

    func testUTXOsAreBoundToCorrectChildAndVerifiedAgainstPreviousTransaction() async throws {
        for chain in chains {
            let database = try WalletDatabase(credential: credential)
            let descriptor = try XCTUnwrap(BitcoinFamilyHDDerivation.descriptors(credential: credential, chain: chain)
                .first { $0.type == chain.familyHDDefaultType })
            let child = try BitcoinFamilyHDDerivation.address(descriptor: descriptor, branch: .external, index: 0)
            // A synthetic funding transaction; no real wallet or funds involved.
            var raw = Data([1, 0, 0, 0, 1])
            raw += Data(repeating: 0, count: 32)
            raw += Data([255, 255, 255, 255, 1, 0, 255, 255, 255, 255, 1])
            raw += Data([0, 225, 245, 5, 0, 0, 0, 0]) // 100,000,000 atomic units
            raw += Data([UInt8(child.scriptPubKey.count)]) + child.scriptPubKey + Data(repeating: 0, count: 4)
            let funding = try XCTUnwrap(BitcoinRawTransaction(hex: raw.hexString))
            let rawHex = raw.hexString
            for amount in [100_000_000, 100_000_001, 0] {
                let client = BitcoinFamilyElectrumClient { _, method, parameter in
                    switch method {
                    case "blockchain.headers.subscribe": return .object(["height": .string("1000")])
                    case "blockchain.scripthash.get_balance": return .object([
                        "confirmed": .string(parameter == child.scriptHash ? "100000000" : "0"), "unconfirmed": .string("0")])
                    case "blockchain.scripthash.get_history": return parameter == child.scriptHash
                        ? .array([.object(["tx_hash": .string(funding.transactionID), "height": .string("900")])]) : .array([])
                    case "blockchain.scripthash.listunspent", "blockchain.scripthash.listunspent#ranked":
                        if amount == 0 && !method.hasSuffix("#ranked") { return .array([]) }
                        return .array([.object([
                        "tx_hash": .string(funding.transactionID), "tx_pos": .string("0"),
                        "height": .string("900"), "value": .string(String(amount == 0 ? 100_000_000 : amount))])])
                    case "blockchain.transaction.get": return .string(rawHex)
                    default: throw BitcoinFamilyElectrumError.invalidResponse
                    }
                }
                do {
                    let outputs = try await HostUTXOReader(electrum: client).outputs(database: database, chain: chain)
                    XCTAssertNotEqual(amount, 100_000_001, "A provider cannot invent an input's value")
                    XCTAssertEqual(outputs.count, 1)
                    XCTAssertEqual(outputs.first?.owner, child)
                    XCTAssertEqual(outputs.first?.valueAtomic, "100000000")
                    XCTAssertEqual(outputs.first?.confirmations, 101)
                } catch {
                    if amount != 100_000_001 { throw error }
                    guard case SendBitcoinUTXORepositoryError.invalidResponse("family_hd_previous_output") = error else { throw error }
                }
            }
        }
    }

    func testNativeBCHBatchAndFallbackExcludeCashTokens() throws {
        for chain in chains {
            let batch = try hostRPCParameters(chain: chain, method: "blockchain.scripthash.listunspent", parameter: "hash")
            let ranked = HostUTXOReader.listUnspentParameters(chain: chain, scriptHash: "hash")
            let first = try JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String]
            let second = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ranked)) as? [String]
            XCTAssertEqual(first, second)
            XCTAssertEqual(first, chain == .bitcoinCash ? ["hash", "exclude_tokens"] : ["hash"])
        }
    }

    func testCustomFeesAndDustAreConsistentBetweenReviewAndSigning() throws {
        for chain in chains {
            let descriptor = try XCTUnwrap(BitcoinFamilyHDDerivation.descriptors(credential: credential, chain: chain)
                .first { $0.type == chain.familyHDDefaultType })
            let owner = try BitcoinFamilyHDDerivation.address(descriptor: descriptor, branch: .external, index: 2)
            let recipient = try BitcoinFamilyHDDerivation.address(descriptor: descriptor, branch: .external, index: 3)
            let change = try BitcoinFamilyHDDerivation.address(descriptor: descriptor, branch: .change, index: 2)
            let utxo = SendBitcoinUTXO(networkID: chain.networkID,
                outpoint: SendBitcoinOutpoint(transactionHash: String(repeating: "12", count: 32), outputIndex: 0),
                valueAtomic: "100000000", blockHeight: 100, confirmations: 5, owner: owner)
            let rate: Int64 = chain == .dogecoin ? 1000 : 10
            let fee = SendResolvedNetworkFee(model: .satoshiPerByte, primaryValue: String(rate), secondaryValue: nil,
                                            totalBudgetAtomic: "2000000")
            let request: Int64 = chain == .dogecoin ? 100_000 : 50_000_000
            let reviewed = try SendBitcoinFamilyHDTransactionSigner.selectionPlan(draft: SendDraft(), chain: chain, outputs: [utxo],
                requestedAtomic: request, byteFee: rate, fee: fee, options: .automatic,
                changeAddress: change.address, recipientAddress: recipient.address)
            let signed = try SendBitcoinFamilyHDTransactionSigner.sign(draft: SendDraft(),
                material: SendResolvedSigningMaterial(bitcoinHDRecoveryCredential: credential), chain: chain, outputs: [utxo],
                requestedAtomic: request, byteFee: rate, fee: fee, options: .automatic,
                changeAddress: change.address, recipientAddress: recipient.address)
            XCTAssertEqual(reviewed.feeAtomic, "2000000")
            XCTAssertEqual(signed.feeAtomic, reviewed.feeAtomic)
            XCTAssertEqual(signed.amountAtomic, String(request))
            XCTAssertThrowsError(try SendBitcoinFamilyHDTransactionSigner.selectionPlan(draft: SendDraft(), chain: chain, outputs: [utxo],
                requestedAtomic: 1, byteFee: rate, fee: fee, options: .automatic,
                changeAddress: change.address, recipientAddress: recipient.address))
            let other = BitcoinFamilyChain.dogecoin == chain ? BitcoinFamilyChain.litecoin : .dogecoin
            XCTAssertThrowsError(try SendBitcoinFamilyHDTransactionSigner.input(draft: SendDraft(), chain: other, outputs: [utxo],
                requestedAtomic: request, byteFee: rate, options: .automatic,
                changeAddress: change.address, recipientAddress: recipient.address))
        }
    }

    func testLiveMainnetAddressesBalancesAndTransactions() async throws {
        let database = try WalletDatabase(credential: credential)
        let client = BitcoinFamilyElectrumClient()
        let service = BitcoinFamilyHDDiscoveryService(database: database, electrum: client)
        let records = try await withThrowingTaskGroup(of: String.self) { group in
            for chain in chains {
                group.addTask {
                    let features = try await client.call(chain: chain, method: "server.features", parameter: "")
                    XCTAssertEqual(features.object?["genesis_hash"]?.string, chain.genesisHash)
                    let scan = try await service.discover(walletID: "fixture", chain: chain)
                    XCTAssertGreaterThanOrEqual(scan.states.count, chain.familyHDTypes.count * 10)
                    XCTAssertFalse(scan.balance.isNegative)
                    let sampleOwner = try XCTUnwrap(scan.states.first?.derived)
                    let unspent = try await client.call(chain: chain, method: "blockchain.scripthash.listunspent",
                        parameter: sampleOwner.scriptHash)
                    XCTAssertNotNil(unspent.array, "Mainnet server accepts native-only output parameters")
                    let history = try await HostHistoryReader(chain: chain, client: client).transactionEntries(
                        references: Array(scan.transactions.prefix(3)),
                        ownedAddresses: Dictionary(uniqueKeysWithValues: scan.states.map { ($0.derived.scriptPubKey, $0.derived.address) }))
                    XCTAssertEqual(history.count, min(3, scan.transactions.count))
                    for entry in history {
                        XCTAssertFalse(entry.amountAtomic.isNegative)
                        XCTAssertNotNil(entry.feeAtomic)
                        XCTAssertNotNil(entry.timestamp)
                        if let address = entry.identity?.fromAddress { XCTAssertTrue(chain.coin.validate(address: address)) }
                        if let address = entry.identity?.toAddress { XCTAssertTrue(chain.coin.validate(address: address)) }
                    }
                    var verified = 0
                    for reference in scan.transactions.prefix(3) {
                        let raw = try await client.call(chain: chain, method: "blockchain.transaction.get", parameter: reference.transactionHash)
                        let tx = try XCTUnwrap(BitcoinRawTransaction(hex: raw.string ?? ""))
                        XCTAssertEqual(tx.transactionID, reference.transactionHash)
                        verified += 1
                    }
                    let record: [String: Any] = ["chain": chain.rawValue, "checkedAddresses": scan.states.count,
                        "balanceAtomic": scan.balance.decimalText, "historyCount": scan.transactions.count,
                        "verifiedRawTransactions": verified, "nextReceiveAddress": scan.receiveAddress.address,
                        "reconstructedHistory": history.map { ["txid": $0.transactionHash, "direction": $0.direction,
                            "amount": $0.amountAtomic.decimalText, "fee": $0.feeAtomic?.decimalText ?? "unknown"] },
                        "genesisHash": chain.genesisHash,
                        "addresses": scan.states.map { ["address": $0.derived.address, "path": $0.derived.derivationPath,
                            "confirmed": $0.confirmedBalanceAtomic.decimalText, "unconfirmed": $0.unconfirmedBalanceAtomic.decimalText,
                            "used": String($0.isUsed)] }]
                    let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                    return String(decoding: bytes, as: UTF8.self)
                }
            }
            var results: [String] = []
            for try await record in group { results.append(record) }
            return results.sorted()
        }
        try ("[" + records.joined(separator: ",\n") + "]")
            .write(toFile: NSTemporaryDirectory() + "aperture-family-hd/live-results.json", atomically: true, encoding: .utf8)
    }
}

actor RequestActivity {
    var active = 0
    var count = 0
    var maximum = 0
    var chains = Set<BitcoinFamilyChain>()
    func start(chain: BitcoinFamilyChain) { count += 1; active += 1; maximum = max(maximum, active); chains.insert(chain) }
    func end() { active -= 1 }
    func snapshot() -> (count: Int, maximum: Int, chains: Set<BitcoinFamilyChain>) { (count, maximum, chains) }
}
