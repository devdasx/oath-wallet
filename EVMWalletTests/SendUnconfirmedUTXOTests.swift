import Foundation
import Testing
import WalletCore
@testable import Aperture

struct SendUnconfirmedUTXOTests {
    @Test(arguments: BitcoinFamilyChain.allCases)
    func signsParentThenSpendsItsUnconfirmedChange(chain: BitcoinFamilyChain) throws {
        let key = try #require(PrivateKey(data: Data(repeating: 0x11, count: 32)))
        let recipientKey = try #require(PrivateKey(data: Data(repeating: 0x22, count: 32)))
        let sender = chain.coin.deriveAddress(privateKey: key)
        let recipient = chain.coin.deriveAddress(privateKey: recipientKey)
        let funding = output(chain, hash: String(repeating: "ab", count: 32), value: "200000000", confirmed: true)
        let parent = try sign(chain, key: key, sender: sender, recipient: recipient, inputs: [funding], amount: 50_000_000)
        let parentRaw = try #require(BitcoinRawTransaction(hex: parent.encoded.hexString))
        let consumed = try SendSpendResource.bitcoinInputs(rawHex: parent.encoded.hexString, transactionID: parent.transactionID)
        #expect(consumed == [.init(kind: .outpoint, value: funding.id)])
        let changeScript = BitcoinScript.lockScriptForAddress(address: sender, coin: chain.coin).data
        let changeIndex = try #require(parentRaw.outputs.firstIndex { $0.script == changeScript })
        let change = SendBitcoinUTXO(
            networkID: chain.networkID,
            outpoint: .init(transactionHash: parent.transactionID, outputIndex: changeIndex),
            valueAtomic: parentRaw.outputs[changeIndex].value.decimalText,
            blockHeight: 0, confirmations: 0
        )
        #expect(change.isValid)
        // A lagging provider may return the old spent funding input alongside
        // the new unconfirmed change. Only the old input must be excluded.
        let available = SendSpendResource.availableBitcoinOutputs([funding, change], excluding: consumed)
        #expect(available == [change])
        let selected = try SendBitcoinTransactionService.outputs(from: available, selection: .manual([change]))
        let child = try sign(chain, key: key, sender: sender, recipient: recipient, inputs: selected, amount: 25_000_000)
        let childRaw = try #require(BitcoinRawTransaction(hex: child.encoded.hexString))
        #expect(childRaw.inputs.count == 1)
        #expect(childRaw.inputs[0].previousHash == parent.transactionID.lowercased())
        #expect(childRaw.inputs[0].previousIndex == changeIndex)
        #expect(child.transactionID != parent.transactionID)
        #expect(try SendSpendResource.bitcoinInputs(rawHex: child.encoded.hexString, transactionID: child.transactionID) == [.init(kind: .outpoint, value: change.id)])
        // Neither a stale manual selection nor a mismatching txid may unlock it.
        #expect(throws: SendTransactionSubmissionError.self) {
            try SendBitcoinTransactionService.outputs(from: available, selection: .manual([funding]))
        }
        #expect(throws: WalletDataStoreError.self) {
            try SendSpendResource.bitcoinInputs(rawHex: child.encoded.hexString, transactionID: parent.transactionID)
        }
    }

    @Test(arguments: BitcoinFamilyChain.allCases)
    func unconfirmedIncomingAndUnrelatedOutputsRemainAvailable(chain: BitcoinFamilyChain) {
        let spent = output(chain, hash: String(repeating: "a", count: 64), value: "1000", confirmed: true)
        let incoming = output(chain, hash: String(repeating: "b", count: 64), value: "2000", confirmed: false)
        let independent = output(chain, hash: String(repeating: "c", count: 64), value: "3000", confirmed: true)
        #expect(SendSpendResource.availableBitcoinOutputs(
            [spent, incoming, independent], excluding: [.init(kind: .outpoint, value: spent.id)]
        ) == [incoming, independent])
    }

    private func output(_ chain: BitcoinFamilyChain, hash: String, value: String, confirmed: Bool) -> SendBitcoinUTXO {
        SendBitcoinUTXO(networkID: chain.networkID, outpoint: .init(transactionHash: hash, outputIndex: 0), valueAtomic: value,
                        blockHeight: confirmed ? 900_000 : 0, confirmations: confirmed ? 12 : 0)
    }

    private func sign(_ chain: BitcoinFamilyChain, key: PrivateKey, sender: String, recipient: String,
                      inputs: [SendBitcoinUTXO], amount: Int64) throws -> BitcoinSigningOutput {
        let asset = SendAssetChoice(
            id: AssetIdentityKey.make(networkID: chain.networkID, contractAddress: nil), name: "Fixture", symbol: chain.symbol,
            networkID: chain.networkID, networkName: "Fixture", blockchain: chain.blockchain,
            contractAddress: nil, decimals: 8, logoSource: .nativeCoin(blockchain: chain.blockchain),
            networkLogoSource: .network(blockchain: chain.blockchain), balance: 2, fiatValue: 0, balanceAtomic: "200000000"
        )
        let draft = SendDraft(request: .manualEntry(networkID: chain.networkID), asset: asset,
                              recipient: recipient, amount: "0.5", note: nil)
        var input = try SendBitcoinTransactionService.signingInput(
            draft: draft, accountMarker: nil, nestedSegwitPublicKey: nil, chain: chain, outputs: inputs,
            requestedAtomic: amount, byteFee: chain == .dogecoin ? 1000 : 2, options: .automatic,
            senderAddress: sender, recipientAddress: recipient
        )
        let plan: BitcoinTransactionPlan = AnySigner.plan(input: input, coin: chain.coin)
        #expect(plan.error == .ok)
        #expect(plan.amount == amount)
        #expect(plan.fee > 0)
        #expect(plan.change > 0)
        input.plan = plan
        input.privateKey = [key.data]
        let signed: BitcoinSigningOutput = AnySigner.sign(input: input, coin: chain.coin)
        #expect(signed.error == .ok)
        #expect(!signed.encoded.isEmpty)
        let parsed = try #require(BitcoinRawTransaction(hex: signed.encoded.hexString))
        #expect(parsed.transactionID == signed.transactionID.lowercased())
        let outputSum = parsed.outputs.reduce("0") { SendAtomicAmount.add($0, $1.value.decimalText) }
        let inputSum = inputs.reduce("0") { SendAtomicAmount.add($0, $1.valueAtomic) }
        #expect(SendAtomicAmount.add(outputSum, String(plan.fee)) == inputSum)
        return signed
    }
}
