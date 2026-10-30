import Foundation
import OathSecp256k1

/// Pinned Safe L2 1.4.1, with no modules, guard, fallback handler or delegatecall.
/// The same policy and bytecode checks apply on testnet and mainnet.
public struct EVMMultisigPolicy: Codable, Sendable, Equatable {
    public static let maximumKeys = 15
    public static let factory = "0x4e1dcf7ad4e460cfd30791ccc4f9c8a4f820ec67"
    public static let singleton = "0x29fcb43b46531bca003ddc8fcb67ffe91900c762"
    static let factoryHash = "50c3cdc4074750a7a974204a716c999edd37482f907608d960b2b025ee0b3317"
    static let singletonHash = "b1f926978a0f44a2c0ec8fe822418ae969bd8c3f18d61e5103100339894f81ff"
    static let proxyCreation = "608060405234801561001057600080fd5b506040516101e63803806101e68339818101604052602081101561003357600080fd5b8101908080519060200190929190505050600073ffffffffffffffffffffffffffffffffffffffff168173ffffffffffffffffffffffffffffffffffffffff1614156100ca576040517f08c379a00000000000000000000000000000000000000000000000000000000081526004018080602001828103825260228152602001806101c46022913960400191505060405180910390fd5b806000806101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff1602179055505060ab806101196000396000f3fe608060405273ffffffffffffffffffffffffffffffffffffffff600054167fa619486e0000000000000000000000000000000000000000000000000000000060003514156050578060005260206000f35b3660008037600080366000845af43d6000803e60008114156070573d6000fd5b3d6000f3fea264697066735822122003d1488ee65e08fa41e58e888a9865554c535f2c77126a82cb4c0f917f31441364736f6c63430007060033496e76616c69642073696e676c65746f6e20616464726573732070726f7669646564"
    static let proxyRuntime = "608060405273ffffffffffffffffffffffffffffffffffffffff600054167fa619486e0000000000000000000000000000000000000000000000000000000060003514156050578060005260206000f35b3660008037600080366000845af43d6000803e60008114156070573d6000fd5b3d6000f3fea264697066735822122003d1488ee65e08fa41e58e888a9865554c535f2c77126a82cb4c0f917f31441364736f6c63430007060033"
    public let required: Int
    public let owners: [String]
    public let salt: Data
    public let executor: String
    public init(required: Int, owners: [String], salt: Data, executor: String) throws {
        self.required = required; self.owners = try owners.map(EVMSendIdentity.address).sorted()
        self.salt = salt; self.executor = try EVMSendIdentity.address(executor)
        try validate()
    }
    public func validate() throws {
        guard (2...Self.maximumKeys).contains(owners.count), (1...owners.count).contains(required), salt.count == 32,
              owners == owners.sorted(), Set(owners).count == owners.count,
              try EVMSendIdentity.address(executor) == executor, executor != SafeABI.zero,
              !owners.contains(executor) else { throw EVMSendError.configuration }
        for owner in owners {
            guard try EVMSendIdentity.address(owner) == owner, owner != SafeABI.zero,
                  owner != "0x0000000000000000000000000000000000000001" else { throw EVMSendError.configuration }
        }
    }
    public var address: String {
        get throws {
            try validate()
            let saltHash = TronSendCrypto.keccak(try TronSendCrypto.keccak(initializer()) + salt)
            let code = try TronIdentity.hex(Self.proxyCreation) + SafeABI.address(Self.singleton)
            return "0x" + TronSendCrypto.hex(TronSendCrypto.keccak(try Data([255]) + TronIdentity.hex(Self.factory) + saltHash + TronSendCrypto.keccak(code)).suffix(20))
        }
    }
    func initializer() throws -> Data {
        var data = SafeABI.selector("setup(address[],uint256,address,bytes,address,address,uint256,address)")
        data += try SafeABI.uint(256) + SafeABI.uint(required) + SafeABI.address(SafeABI.zero)
        data += try SafeABI.uint(256 + 32 + owners.count * 32) + SafeABI.address(SafeABI.zero)
        data += try SafeABI.address(SafeABI.zero) + SafeABI.uint(0) + SafeABI.address(SafeABI.zero)
        data += try SafeABI.uint(owners.count) + owners.map(SafeABI.address).reduce(Data(), +)
        data += try SafeABI.bytes(Data())
        return data
    }
    public func deploymentData() throws -> Data {
        try validate()
        return try SafeABI.selector("createProxyWithNonce(address,bytes,uint256)") + SafeABI.address(Self.singleton)
            + SafeABI.uint(96) + salt + SafeABI.bytes(initializer())
    }
}

/// Only public policy/state is persisted in send plans. Secrets stay in the vault.
public struct EVMMultisigContext: Codable, Sendable, Equatable {
    public let policy: EVMMultisigPolicy
    public let safeNonce: UInt64
    public let executorBalance: String
    public let setup: Bool
    public init(policy: EVMMultisigPolicy, safeNonce: UInt64, executorBalance: String, setup: Bool = false) {
        self.policy = policy; self.safeNonce = safeNonce; self.executorBalance = executorBalance; self.setup = setup
    }
}

enum SafeABI {
    static let zero = "0x" + String(repeating: "0", count: 40)
    static func selector(_ value: String) -> Data { Data(TronSendCrypto.keccak(Data(value.utf8)).prefix(4)) }
    static func uint(_ n: Int) throws -> Data { try TronSendCrypto.uint256(String(n)) }
    static func address(_ a: String) throws -> Data { try Data(repeating: 0, count: 12) + TronIdentity.hex(EVMSendIdentity.address(a)) }
    static func bytes(_ d: Data) throws -> Data { try uint(d.count) + d + Data(repeating: 0, count: (32 - d.count % 32) % 32) }
}

public enum EVMMultisigCrypto {
    public static func digest(_ p: EVMSendPlan) throws -> Data {
        guard let m = p.multisig, !m.setup else { throw EVMSendError.changed }
        let domain = try TronSendCrypto.keccak(TronSendCrypto.keccak(Data("EIP712Domain(uint256 chainId,address verifyingContract)".utf8))
            + TronSendCrypto.uint256(String(p.network.chainID)) + SafeABI.address(p.sender))
        let type = TronSendCrypto.keccak(Data("SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)".utf8))
        let body = try type + SafeABI.address(p.receiver) + TronSendCrypto.uint256(p.value)
            + TronSendCrypto.keccak(EVMSendCrypto.data(p)) + Data(repeating: 0, count: 32 * 6)
            + TronSendCrypto.uint256(String(m.safeNonce))
        return TronSendCrypto.keccak(Data([25, 1]) + domain + TronSendCrypto.keccak(body))
    }
    public static func executionData(_ p: EVMSendPlan, signatures: Data) throws -> Data {
        guard let m = p.multisig else { throw EVMSendError.changed }
        if m.setup { return try m.policy.deploymentData() }
        let data = try SafeABI.bytes(EVMSendCrypto.data(p))
        return try SafeABI.selector("execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)")
            + SafeABI.address(p.receiver) + TronSendCrypto.uint256(p.value) + SafeABI.uint(320)
            + Data(repeating: 0, count: 32 * 6) + SafeABI.uint(320 + data.count) + data + SafeABI.bytes(signatures)
    }
    public static func outer(_ p: EVMSendPlan, signatures: Data) throws -> EVMSendPlan {
        guard let m = p.multisig else { throw EVMSendError.changed }
        return .init(network: p.network, sender: m.policy.executor,
            recipient: m.setup ? EVMMultisigPolicy.factory : p.sender, reference: "native", decimals: 18,
            requestedAmount: "0", amount: "0", assetBalance: m.executorBalance, nativeBalance: m.executorBalance,
            nonce: p.nonce, gasLimit: p.gasLimit, maxFeePerGas: p.maxFeePerGas,
            maxPriorityFeePerGas: p.maxPriorityFeePerGas, blockHeight: p.blockHeight, createdAt: p.createdAt,
            legacy: p.legacy, extraFee: p.extraFee, call: try EVMContractCall(hex: "0x" + TronSendCrypto.hex(executionData(p, signatures: signatures))))
    }
    public static func sign(_ p: EVMSendPlan, keys: [Data], executorKey: Data) throws -> EVMSignedSend {
        try p.validate()
        guard let m = p.multisig, try EVMSendCrypto.address(privateKey: executorKey) == m.policy.executor else { throw EVMSendError.wrongOwner }
        var signatures = Data()
        if !m.setup {
            let pairs = try keys.map { (try EVMSendCrypto.address(privateKey: $0), $0) }.sorted { $0.0 < $1.0 }
            guard pairs.count >= m.policy.required, Set(pairs.map(\.0)).count == pairs.count,
                  pairs.allSatisfy({ m.policy.owners.contains($0.0) }) else { throw EVMSendError.wrongOwner }
            let hash = try digest(p)
            for (_, key) in pairs.prefix(m.policy.required) {
                var s = try OathSecp256k1.signRecoverable(hash, key: key)
                guard s.count == 65, s[64] <= 1 else { throw EVMSendError.signing }
                s[64] += 27; signatures += s
            }
        }
        let signed = try EVMSendCrypto.sign(outer(p, signatures: signatures), privateKey: executorKey)
        let result = EVMSignedSend(bytes: signed.bytes, signature: signed.signature, hash: signed.hash, multisigSignatures: signatures)
        try verify(result, plan: p)
        return result
    }
    public static func verify(_ signed: EVMSignedSend, plan p: EVMSendPlan) throws {
        try p.validate(checkAge: false)
        guard let m = p.multisig, let sigs = signed.multisigSignatures, signed.authorizationSignature == nil,
              sigs.count == (m.setup ? 0 : m.policy.required * 65) else { throw EVMSendError.signing }
        if !m.setup {
            let hash = try digest(p)
            var last = ""
            for i in stride(from: 0, to: sigs.count, by: 65) {
                var sig = Data(sigs[i..<i+65]); guard (27...28).contains(sig[64]) else { throw EVMSendError.signing }; sig[64] -= 27
                let pub = try OathSecp256k1.recover(sig, digest: hash)
                let owner = "0x" + TronSendCrypto.hex(TronSendCrypto.keccak(Data(pub.dropFirst())).suffix(20))
                guard pub.count == 65, owner > last, m.policy.owners.contains(owner) else { throw EVMSendError.signing }; last = owner
            }
        }
        try EVMSendCrypto.verify(.init(bytes: signed.bytes, signature: signed.signature, hash: signed.hash), plan: outer(p, signatures: sigs))
    }
}
