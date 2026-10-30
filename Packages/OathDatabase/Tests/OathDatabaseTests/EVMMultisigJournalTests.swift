import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class EVMMultisigJournalTests: XCTestCase {
    func testSetupAndTransferPersistRestartHistoryAndExclusiveNonce() async throws {
        for network in [EVMSendNetwork.ethereum, .arc] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SafeJournal-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
        let keys = [Data(repeating:1,count:32),Data(repeating:2,count:32)], executor = Data(repeating:3,count:32)
        let policy = try EVMMultisigPolicy(required:2,owners:keys.map{try EVMSendCrypto.address(privateKey:$0)},salt:Data(repeating:4,count:32),executor:EVMSendCrypto.address(privateKey:executor))
        let owner = try policy.address, token = "0x"+String(repeating:"b",count:40)
        try await db.seed(networks:[.init(id:network.rawValue,name:"Ethereum",family:"account",symbol:"ETH",decimals:18,derivationPath:"m/44'/60'/0'/0/0",logo:network.rawValue,sortOrder:0)],assets:[.init(id:network.rawValue + ":native",networkID:network.rawValue,reference:"native",name:"ETH",symbol:"ETH",decimals:18),.init(id:network.rawValue + ":"+token,networkID:network.rawValue,reference:token,name:"Token",symbol:"TEST",decimals:6)])
        try await db.importWalletIfNeeded(.init(id:"w",name:"Fixture",kind:"evmMultisig",vaultReference:"test",createdAt:1),accounts:[.init(id:"a",walletID:"w",networkID:network.rawValue,address:owner,derivationPath:"evm-multisig-v1")])
        _ = try await db.trackAsset(.init(id:network.rawValue + ":" + token, networkID:network.rawValue, reference:token, name:"Token", symbol:"TEST", decimals:6), walletID:"w")
        for (index,ref) in ["setup","native",token].enumerated() {
            let setup = ref == "setup", reference = setup ? "native":ref
            let p = EVMSendPlan(network:network,sender:owner,recipient:setup ? EVMMultisigPolicy.factory : "0x"+String(repeating:"a",count:40),reference:reference,decimals:reference == "native" ? 18:6,requestedAmount:setup ? "0":"123",amount:setup ? "0":"123",assetBalance:"1000",nativeBalance:reference == "native" ? "1000":"0",nonce:UInt64(index),gasLimit:300000,maxFeePerGas:1000000000,maxPriorityFeePerGas:1,blockHeight:100,multisig:.init(policy:policy,safeNonce:UInt64(max(0,index-1)),executorBalance:"1000000000000000000",setup:setup))
            let id="send-\(index)"
            func draft(_ id:String) async throws {
                try await db.saveDraft(.init(id:id,walletID:"w",accountID:"a",networkID:network.rawValue,assetID:network.rawValue + ":"+reference,idempotencyKey:id,recipient:p.recipient,amountAtomic:p.amount,state:"draft",createdAt:1,updatedAt:1))
            }
            try await draft(id);try await db.queueEVMSend(sendID:id,plan:p)
            let signed=try EVMMultisigCrypto.sign(p,keys:keys,executorKey:executor)
            try await db.journalEVMSignature(sendID:id,signed:signed)
            let details = try await db.transactionDetails(accountID: "a", transactionID: network.rawValue + ":" + signed.hash)
            if setup { XCTAssertNil(details, "Configuration is not a transfer receipt") }
            else {
                XCTAssertEqual(details?.fromAddresses, [owner], "Show the wallet, not its fee-paying executor")
                XCTAssertEqual(details?.toAddresses, [p.recipient], "Show the token recipient, not the token contract")
            }
            try await draft(id+"-duplicate")
            do { try await db.queueEVMSend(sendID:id+"-duplicate",plan:p);XCTFail("Safe must not allow concurrent nonce reuse") } catch { XCTAssertEqual(error as? EVMSendError,.busy) }
            let reopened=try await OathDatabase.open(at:folder.appendingPathComponent("db.sqlite"))
            let restored=try await reopened.send(id)
            let decoded=try JSONDecoder().decode(EVMSignedSend.self,from:XCTUnwrap(restored?.signedPayload))
            try EVMSendCrypto.verify(decoded,plan:p)
            _ = try await reopened.transitionSend(id,from:"signed",to:"broadcast")
            try await reopened.settleEVMSend(sendID:id,receipt:.init(hash:signed.hash,outcome:.accepted))
            let pending=try await reopened.send(id);XCTAssertEqual(pending?.state,"broadcast")
            let receipt=EVMSendReceipt(hash:signed.hash,outcome:.confirmed,fee:10000,height:101,timestamp:123,deliveredAmount:reference == "native" ? nil:p.amount)
            try await reopened.settleEVMSend(sendID:id,receipt:receipt)
            try await reopened.settleEVMSend(sendID:id,receipt:receipt)
            let rows=try await reopened.pool.read { try ActivityRecord.fetchAll($0,sql:"SELECT * FROM activity WHERE transactionID=?",arguments:[network.rawValue + ":"+signed.hash]) }
            XCTAssertEqual(rows.count,setup ? 0:1)
            if !setup { XCTAssertEqual(rows.first?.amountAtomic,"123");XCTAssertEqual(rows.first?.accountID,"a") }
            let result=try await reopened.send(id);XCTAssertEqual(result?.state,"confirmed")
            let history = try await reopened.history(walletID:"w")
            let visible = history.filter { $0.transactionID == network.rawValue + ":" + signed.hash }
            XCTAssertEqual(visible.count,setup ? 0:1)
            if !setup {
                XCTAssertEqual(visible.first?.amountAtomic,"123")
                XCTAssertEqual(visible.first?.direction,"outgoing")
                XCTAssertEqual(visible.first?.state,"confirmed")
            }
        }
        }
    }
}
