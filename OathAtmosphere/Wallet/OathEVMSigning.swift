import Foundation
import WalletCore
import OathCloudBackup
import OathDatabase
import OathAnkr

extension OathWalletEngine {
    static func signEVM(_ plan: EVMSendPlan, secret: OathWalletSecret, account: AccountRecord) throws -> EVMSignedSend {
        try Task.checkCancellation()
        guard account.walletID == secret.id.uuidString, account.networkID == plan.network.rawValue,
              let chain=OathImportChain(rawValue:account.networkID),chain.isEVM,
              try EVMSendIdentity.address(account.address) == plan.sender else { throw EVMSendError.wrongOwner }
        if let material = secret.evmMultisig {
            guard material.network == account.networkID, account.derivationPath == "evm-multisig-v1",
                  let context = plan.multisig, try context.policy == material.policy() else { throw EVMSendError.wrongOwner }
            var keys = try material.signers.map { try $0.signingKey() }
            defer { for i in keys.indices { keys[i].resetBytes(in: 0..<keys[i].count) } }
            return try EVMMultisigCrypto.sign(plan, keys: keys, executorKey: material.executorKey)
        }
        guard plan.multisig == nil else { throw EVMSendError.wrongOwner }
        var bytes: Data
        if let material = secret.privateKey {
            guard material.isValidStructure, (material.networks.contains(chain) || material.isFullEVMScope), account.derivationPath == "imported" else { throw EVMSendError.wrongOwner }
            bytes = material.bytes
        } else {
            let passphrase = try secret.bip39Passphrase
            guard OathMnemonicValidator.bundled?.verifiedPhrase(secret.mnemonic) != nil,
                  let wallet = HDWallet(mnemonic:secret.mnemonic,passphrase:passphrase,check:false),
                  let key = wallet.getKey(coin:.ethereum,derivationPath:account.derivationPath) else { throw OathWalletError.derivationFailed }
            bytes = key.data
        }
        defer { bytes.resetBytes(in:0..<bytes.count) }
        // Address equality validates the exact derived/imported signing key.
        return try EVMSendCrypto.sign(plan,privateKey:bytes)
    }
}
