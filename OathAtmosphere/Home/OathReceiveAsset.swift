import Foundation
import OathDatabase
import OathBitcoin

/// Bind each asset to its own persisted account, including tokens and alternate
/// receive paths. Matching only a network can send a second account's QR to the
/// first account, so an exact account/network match is required.
struct OathReceiveAsset: Identifiable {
    let holding: Holding
    let address: OathWalletAddress
    var id: String { holding.id }

    /// A fee deposit belongs to the sending account, even when another account
    /// on the same network appears first or the native asset is hidden.
    static func feeAddress(for holding: Holding, in snapshot: WalletSnapshot) -> OathWalletAddress? {
        guard let chain = OathImportChain(rawValue: holding.networkID),
              let account = snapshot.accounts.first(where: {
                  $0.id == holding.accountID && $0.walletID == snapshot.wallet.id && $0.networkID == holding.networkID
              }) else { return nil }
        let native = snapshot.holdings.first {
            $0.accountID == account.id && $0.networkID == account.networkID && $0.reference == "native"
        }
        return OathWalletAddress(chain: chain, address: holding.address, path: account.derivationPath,
                                 accountIndex: account.accountIndex, accountID: account.id,
                                 assetID: native?.assetID ?? chain.id + ":native")
    }

    /// Only a native-only network with one account can bypass asset selection.
    /// Token networks keep discovery/search available even before tokens are held.
    static func directAddress(in addresses: [OathWalletAddress]) -> OathWalletAddress? {
        guard addresses.count == 1, let address = addresses.first, !address.chain.supportsTokens else { return nil }
        return address
    }

    static func available(holdings: [Holding], addresses: [OathWalletAddress], query: String) -> [Self] {
        let accounts = Dictionary(grouping: addresses.compactMap { address in
            address.accountID.map { ($0, address) }
        }, by: { $0.0 })
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        // Empty search results and absent accounts are normal UI states.
        let assets: [Self] = holdings.compactMap { holding in
            guard let account = accounts[holding.accountID]?.first(where: {
                $0.1.chain.id == holding.networkID
            })?.1, words.allSatisfy({ word in
                [holding.name, holding.symbol, holding.networkID, holding.reference,
                 account.chain.name, account.networkName].contains {
                    $0.localizedStandardContains(word)
                }
            }) else { return nil }
            return Self(holding: holding, address: OathWalletAddress(
                chain: account.chain, address: holding.address, path: account.path,
                accountIndex: account.accountIndex, accountID: holding.accountID, assetID: holding.assetID,
                storedNetworkName: account.storedNetworkName, storedTicker: account.storedTicker,
                storedLogo: account.storedLogo))
        }
        guard !words.isEmpty else { return assets }
        // Network searches put the native coin ahead of tokens regardless of
        // balance. Preserve portfolio order within each group and when not searching.
        return assets.filter { $0.holding.reference == "native" }
            + assets.filter { $0.holding.reference != "native" }
    }
}

/// Receive uses persisted public address policy first. Only first-time setup
/// enters the unlocked vault; neither prices nor network discovery gate the QR.
/// Errors propagate to the receive flow's shared diagnostics boundary.
enum OathReceivePreparation {
    static func bitcoin(database: OathDatabase, accountID: String, walletID: String,
                        network: UTXONetwork, type: BitcoinAddressType? = nil,
                        prepare: @Sendable () async throws -> Void) async throws
        -> (address: BitcoinDerivedAddress, state: BitcoinAccountState) {
        try await validateAccount(database, accountID: accountID, walletID: walletID, networkID: network.rawValue)
        if try await database.bitcoinState(accountID: accountID) == nil { try await prepare() }
        try Task.checkCancellation()
        // Always resolve the first unused address and current persisted type;
        // a profile's original address may already have received funds.
        let address = try await database.bitcoinReceiveAddress(accountID: accountID, type: type)
        guard let state = try await database.bitcoinState(accountID: accountID),
              state.descriptor.network == network else { throw StoreError.conflictingIdentity }
        try Task.checkCancellation()
        return (address, state)
    }

    static func solana(database: OathDatabase, accountID: String, walletID: String, path: String? = nil,
                       prepare: @Sendable () async throws -> SolanaReceiveState) async throws -> SolanaReceiveState {
        try await validateAccount(database, accountID: accountID, walletID: walletID, networkID: "solana")
        let state: SolanaReceiveState
        if let existing = try await database.solanaReceiveState(accountID: accountID) { state = existing }
        else { state = try await prepare() }
        try Task.checkCancellation()
        // Read the actual selected derivation, including for token receipts.
        // Do not replace a Trust/Phantom choice with the profile's old address.
        guard let path else { return state }
        return try await database.selectSolanaReceivePath(accountID: accountID, path: path)
    }

    private static func validateAccount(_ database: OathDatabase, accountID: String,
                                        walletID: String, networkID: String) async throws {
        try Task.checkCancellation()
        guard let account = try await database.account(accountID), account.walletID == walletID,
              account.networkID == networkID else { throw StoreError.conflictingIdentity }
        try Task.checkCancellation()
    }
}
