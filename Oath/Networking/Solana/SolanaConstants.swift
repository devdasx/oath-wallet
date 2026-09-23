import Foundation

enum SolanaConstants {
    static let networkID = "solana"
    static let decimals = 9
    static let nativeSymbol = "SOL"
    static let lamportsPerSOL = Decimal(1_000_000_000)
    static let tokenProgramID =
        "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
    static let token2022ProgramID =
        "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
}

enum SolanaDerivationKind: String, CaseIterable, Identifiable, Sendable {
    case phantom
    case trustWallet

    var id: String { rawValue }

    var derivationPath: String {
        switch self {
        case .phantom:
            "m/44'/501'/0'/0'"
        case .trustWallet:
            "m/44'/501'/0'"
        }
    }

    var localizedNameKey: String {
        switch self {
        case .phantom:
            "receive.solana.path.phantom"
        case .trustWallet:
            "receive.solana.path.trust_wallet"
        }
    }
}
