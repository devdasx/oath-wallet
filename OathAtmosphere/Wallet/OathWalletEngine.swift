import Foundation
import WalletCore
import OathCloudBackup

struct OathWalletAddress: Identifiable, Equatable, Sendable {
    let chain: OathImportChain
    let address: String
    let path: String
    var accountIndex: Int = 0
    var accountID: String? = nil
    var assetID: String? = nil
    var storedNetworkName: String? = nil
    var storedTicker: String? = nil
    var storedLogo: String? = nil
    var networkName: String { storedNetworkName ?? chain.name }
    var ticker: String { storedTicker ?? chain.ticker }
    var logo: String { storedLogo ?? chain.logoAsset }
    // Persisted accounts remain distinct when a wallet owns multiple accounts
    // on one chain. Pure derivation fixtures use the chain as their initial ID.
    var id: String { accountID ?? chain.id }
}

struct OathWalletProfile: Identifiable, Equatable, Sendable {
    let id: UUID
    let addresses: [OathWalletAddress]
    let createdAt: Date
    let backedUp: Bool
}

/// Account 0 / external address 0, with Phantom's default for Solana.
/// EVM networks intentionally share Ethereum's key, including Telos EVM.
enum OathWalletEngine {
    static func create(id: UUID = UUID()) throws -> OathWalletSecret {
        guard let wallet = HDWallet(strength: 128, passphrase: "") else {
            throw OathWalletError.unavailable
        }
        return OathWalletSecret(id: id, mnemonic: wallet.mnemonic, language: "english",
                                createdAt: .now, backedUp: false)
    }

    static func imported(_ phrase: OathValidatedMnemonic, id: UUID = UUID()) throws -> OathWalletSecret {
        guard let verified = OathMnemonicValidator.bundled?.verifiedPhrase(phrase.phrase),
              verified.language == phrase.language else { throw OathWalletError.invalidPhrase }
        return OathWalletSecret(id: id, mnemonic: verified.phrase, language: verified.language,
                                createdAt: .now, backedUp: true, imported: true)
    }

    static func profile(for secret: OathWalletSecret, chains: Set<OathImportChain>? = nil) throws -> OathWalletProfile {
        try Task.checkCancellation()
        if let material = secret.privateKey { return try importedKeyProfile(for: secret, material: material) }
        let passphrase = try secret.bip39Passphrase
        // Our validator checks all ten BIP-39 dictionaries and their checksum.
        // Core's default initializer checks English only. Bypassing that check
        // here preserves the original NFKD phrase for standard BIP-39 seed derivation.
        guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
              let wallet = HDWallet(mnemonic: secret.mnemonic, passphrase: passphrase, check: false) else {
            throw OathWalletError.invalidPhrase
        }
        let accounts = secret.restoration?.accounts ?? OathImportChain.allCases.map {
            BackupWallet.Account(network: $0.id, derivationPath: $0.walletPath, index: 0)
        }
        let addresses = try accounts.filter { account in
            guard let chains else { return true }
            return OathImportChain(rawValue: account.network).map { chains.contains($0) } == true
        }.map { account -> OathWalletAddress in
            try Task.checkCancellation()
            guard let chain = OathImportChain(rawValue: account.network),
                  let key = wallet.getKey(coin: chain.walletCoin, derivationPath: account.derivationPath) else {
                throw OathWalletError.derivationFailed
            }
            let address = chain.walletCoin.deriveAddress(privateKey: key)
            guard !address.isEmpty, AnyAddress.isValid(string: address, coin: chain.walletCoin) else {
                throw OathWalletError.derivationFailed
            }
            return OathWalletAddress(chain: chain, address: address, path: account.derivationPath, accountIndex: account.index)
        }
        return OathWalletProfile(id: secret.id, addresses: addresses,
                                 createdAt: secret.createdAt, backedUp: secret.backedUp)
    }
}

extension OathImportChain {
    var walletCoin: CoinType {
        if isEVM { return .ethereum }
        switch self {
        case .aptos: return .aptos
        case .bitcoin: return .bitcoin
        case .bitcoincash: return .bitcoinCash
        case .dogecoin: return .dogecoin
        case .litecoin: return .litecoin
        case .thorchain: return .thorchain
        case .near: return .near
        case .solana: return .solana
        case .stellar: return .stellar
        case .sui: return .sui
        case .ton: return .ton
        case .tron: return .tron
        case .xrpl: return .xrp
        default: preconditionFailure("Every non-EVM chain must have an explicit mapping")
        }
    }

    var walletPath: String {
        if isEVM { return "m/44'/60'/0'/0/0" }
        switch self {
        case .aptos: return "m/44'/637'/0'/0'/0'"
        case .bitcoin: return "m/84'/0'/0'/0/0"
        case .bitcoincash: return "m/44'/145'/0'/0/0"
        case .dogecoin: return "m/44'/3'/0'/0/0"
        case .litecoin: return "m/84'/2'/0'/0/0"
        case .thorchain: return "m/44'/931'/0'/0/0"
        case .near: return "m/44'/397'/0'"
        case .solana: return "m/44'/501'/0'/0'"
        case .stellar: return "m/44'/148'/0'"
        case .sui: return "m/44'/784'/0'/0'/0'"
        case .ton: return "m/44'/607'/0'"
        case .tron: return "m/44'/195'/0'/0/0"
        case .xrpl: return "m/44'/144'/0'/0/0"
        default: preconditionFailure("Every non-EVM chain must have an explicit path")
        }
    }

    var ticker: String {
        switch self {
        case .aptos: "APT"
        case .bitcoin: "BTC"
        case .bitcoincash: "BCH"
        case .dogecoin: "DOGE"
        case .litecoin: "LTC"
        case .thorchain: "RUNE"
        case .near: "NEAR"
        case .solana: "SOL"
        case .stellar: "XLM"
        case .sui: "SUI"
        case .ton: "GRAM"
        case .tron: "TRX"
        case .xrpl: "XRP"
        case .bnb: "BNB"
        case .fantom: "FTM"
        case .flare: "FLR"
        case .somnia: "SOMI"
        case .story: "IP"
        case .avalanche: "AVAX"
        case .polygon: "POL"
        case .gnosis: "xDAI"
        case .telos: "TLOS"
        case .xlayer: "OKB"
        case .arc: "USDC"
        case .monad: "MON"
        case .hyperevm: "HYPE"
        default: "ETH"
        }
    }
}
