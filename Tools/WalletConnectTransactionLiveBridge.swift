import Foundation
import OathAnkr

/// Opt-in isolated Sepolia fixture. The private key stays in a local 0600 file;
/// stdout contains only public transaction evidence, never signing material.
@main struct WalletConnectTransactionLiveBridge {
    struct Input: Decodable { let keyFile: String?; let transaction: [String: String]?; let journal: String; let statusOnly: Bool?; let editedApprovalAmount: String? }
    struct Fixture: Decodable { let privateKey: String; let sender: String }
    struct Journal: Codable { let plan: EVMSendPlan; let signed: EVMSignedSend }
    struct Output: Encodable { let hash: String; let gasLimit: UInt64; let feeCap: UInt64; let nonce: UInt64; let submissionSeconds: Double; let decodedSteps: Int; let fullyDecoded: Bool }
    static func main() async {
        do { try await run() }
        catch {
            // Closed local enum only: never serialize arbitrary provider errors.
            let category = (error as? EVMSendError).map { String(describing: $0) } ?? String(describing: type(of: error))
            FileHandle.standardError.write(Data("Sepolia bridge failed: \(category)\n".utf8)); exit(1)
        }
    }
    static func run() async throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard data.count < 65_536 else { throw EVMSendError.configuration }
        let input = try JSONDecoder().decode(Input.self, from: data)
        let client = try EVMSendClient(network: .ethereumSepolia, endpoints: [URL(string: "https://ethereum-sepolia-rpc.publicnode.com")!])
        if input.statusOnly == true {
            let saved = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: URL(fileURLWithPath: input.journal)))
            guard saved.plan.network == .ethereumSepolia else { throw EVMSendError.wrongNetwork }
            let receipt = try await client.status(saved.signed, plan: saved.plan)
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["hash": receipt.hash, "outcome": String(describing: receipt.outcome)]))
            return
        }
        guard let keyFile = input.keyFile, let transaction = input.transaction else { throw EVMSendError.configuration }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: keyFile)))
        let key = try TronIdentity.hex(fixture.privateKey.hasPrefix("0x") ? String(fixture.privateKey.dropFirst(2)) : fixture.privateKey)
        let sender = try EVMSendCrypto.address(privateKey: key)
        guard sender.lowercased() == fixture.sender.lowercased(), sender.lowercased() == "0x06b40f932ef96df1dd115040f1d2cdfd7f16d0ef" else { throw EVMSendError.wrongOwner }
        var request = try WalletConnectEVMRequest(params: JSONEncoder().encode([transaction]), account: sender, chainID: 11_155_111)
        if let amount = input.editedApprovalAmount {
            guard try await client.walletConnectApprovalToken(request) != nil else { throw EVMSendError.metadataChanged }
            request = try request.replacingApprovalAmount(amount)
        }
        let plan = try await client.quote(sender: sender, recipient: request.recipient, reference: "native", decimals: 18, amount: request.value, request: request)
        guard request.matches(plan), plan.network.isTestnet else { throw EVMSendError.wrongNetwork }
        try await client.preflight(plan)
        let signed = try EVMSendCrypto.sign(plan, privateKey: key)
        try EVMSendCrypto.verify(signed, plan: plan)
        let journal = URL(fileURLWithPath: input.journal)
        try JSONEncoder().encode(Journal(plan: plan, signed: signed)).write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        let start = Date.now
        let result = try await client.submit(signed, plan: plan, reconcileFirst: false)
        guard result.outcome == .accepted else { throw EVMSendError.execution }
        FileHandle.standardOutput.write(try JSONEncoder().encode(Output(hash: signed.hash, gasLimit: plan.gasLimit,
            feeCap: plan.fee, nonce: plan.nonce, submissionSeconds: Date.now.timeIntervalSince(start),
            decodedSteps: WalletConnectCallDetails(request).steps.count, fullyDecoded: WalletConnectCallDetails(request).fullyDecoded)))
    }
}
