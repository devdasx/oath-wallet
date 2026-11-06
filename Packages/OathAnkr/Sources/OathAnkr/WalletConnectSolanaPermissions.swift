import Foundation

public extension WalletConnectSolanaReview {
    struct Allowance: Sendable, Equatable {
        public let delegate: String
        public let amount: UInt64
        public var unlimited: Bool { amount == UInt64.max }
    }

    /// Permissions are scoped to a token account, not aggregated by mint.
    /// Requested approvals remain visible even when they repeat an existing
    /// allowance or a later instruction revokes it in the same transaction.
    struct Delegation: Sendable, Equatable {
        public let tokenAccount: String, mint: String, program: String
        public let before: Allowance?, after: Allowance?
        public let requested: [Allowance]
        public let decimals: Int?

        func withDecimals(_ decimals: Int?) -> Self {
            .init(tokenAccount: tokenAccount, mint: mint, program: program,
                  before: before, after: after, requested: requested, decimals: decimals)
        }
    }
}

struct WalletConnectSolanaTokenState {
    let mint: String, owner: String, program: String, amount: UInt64
    let allowance: WalletConnectSolanaReview.Allowance?
    let closeAuthority: String?
}

extension SolanaSendClient {
    static func walletConnectTokenState(_ json: SolanaJSON) throws -> WalletConnectSolanaTokenState? {
        guard let program = json["owner"].string,
              [SolanaIdentity.tokenProgram, SolanaIdentity.token2022Program].contains(program) else { return nil }
        guard let data = walletConnectAccountBytes(json) else { throw SolanaSendError.malformed }
        // Mint and multisig accounts are not token accounts. Extended Token-2022
        // mints have padding followed by AccountType::Mint, not Account::Account.
        if data.count == 82 || data.count == 355 { return nil }
        if program == SolanaIdentity.token2022Program, data.count > 165, data[165] == 1 { return nil }
        guard data.count == 165 || (program == SolanaIdentity.token2022Program && data.count > 165 && data[165] == 2),
              data[108] <= 2 else { throw SolanaSendError.malformed }
        let delegate = try optionalKey(data, offset: 72)
        let closeAuthority = try optionalKey(data, offset: 129)
        guard [Data([0,0,0,0]), Data([1,0,0,0])].contains(data.subdata(in: 109..<113)) else { throw SolanaSendError.malformed }
        if data[108] == 0 { return nil } // not initialized yet
        let allowance = delegate.map { WalletConnectSolanaReview.Allowance(delegate: $0, amount: littleEndianAmount(data, offset: 121)) }
        return .init(mint: SolanaSendCrypto.encode(data.prefix(32)),
                     owner: SolanaSendCrypto.encode(data.subdata(in: 32..<64)), program: program,
                     amount: littleEndianAmount(data, offset: 64), allowance: allowance, closeAuthority: closeAuthority)
    }

    static func walletConnectMintDecimals(_ json: SolanaJSON) -> Int? {
        guard let program = json["owner"].string,
              [SolanaIdentity.tokenProgram, SolanaIdentity.token2022Program].contains(program),
              let data = walletConnectAccountBytes(json),
              data.count == 82 || (program == SolanaIdentity.token2022Program && data.count > 165 && data.count != 355 && data[165] == 1),
              data[45] == 1 else { return nil }
        return Int(data[44])
    }

    private static func optionalKey(_ data: Data, offset: Int) throws -> String? {
        let tag = data.subdata(in: offset..<offset+4)
        if tag == Data([0,0,0,0]) { return nil }
        guard tag == Data([1,0,0,0]) else { throw SolanaSendError.malformed }
        return SolanaSendCrypto.encode(data.subdata(in: offset+4..<offset+36))
    }

    static func littleEndianAmount(_ data: Data, offset: Int) -> UInt64 {
        data[offset..<offset+8].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
    }
}

extension WalletConnectSolanaReview {
    static func reviewDelegations(transaction: WalletConnectSolanaTransaction, keys: [String], addresses: [String],
                                  before: [WalletConnectSolanaTokenState?], after: [WalletConnectSolanaTokenState?]) throws -> [Delegation] {
        var requests: [String: [Allowance]] = [:]
        for instruction in transaction.instructions {
            let program = keys[instruction.program]
            guard [SolanaIdentity.tokenProgram, SolanaIdentity.token2022Program].contains(program),
                  let opcode = instruction.data.first, opcode == 4 || opcode == 13 else { continue }
            let checked = opcode == 13
            guard instruction.data.count == (checked ? 10 : 9), instruction.accounts.count >= (checked ? 4 : 3) else { throw SolanaSendError.malformed }
            let source = keys[instruction.accounts[0]], delegate = keys[instruction.accounts[checked ? 2 : 1]]
            guard let index = addresses.firstIndex(of: source), let state = before[index] ?? after[index],
                  state.program == program, !checked || state.mint == keys[instruction.accounts[1]] else { throw SolanaSendError.malformed }
            requests[source, default: []].append(.init(delegate: delegate, amount: SolanaSendClient.littleEndianAmount(instruction.data, offset: 1)))
        }
        var changes = [Delegation]()
        for index in addresses.indices {
            let pre = before[index], post = after[index]
            if let pre, let post {
                guard pre.mint == post.mint, pre.program == post.program else { throw SolanaSendError.malformed }
                // Account-control changes need a dedicated review. Do not let
                // an unsupported authority change masquerade as a balance preview.
                guard pre.owner == post.owner, pre.closeAuthority == post.closeAuthority else { throw SolanaSendError.unsupportedToken }
            }
            guard let state = pre ?? post else { continue }
            let requested = requests[addresses[index], default: []]
            guard pre?.allowance != post?.allowance || !requested.isEmpty else { continue }
            changes.append(.init(tokenAccount: addresses[index], mint: state.mint, program: state.program,
                                 before: pre?.allowance, after: post?.allowance, requested: requested, decimals: nil))
        }
        return changes
    }
}
