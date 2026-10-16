import Foundation

@main enum CheckTransactionExplorer {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        let hex = String(repeating: "ab", count: 32)
        for chain in OathImportChain.allCases {
            let hash = chain.isEVM || chain == .aptos ? "0x" + hex : hex
            let url = chain.transactionExplorerURL(hash: hash)
            check(url?.scheme == "https", "HTTPS route for \(chain)")
            check(url?.absoluteString.contains(hash) == true, "Unchanged complete hash for \(chain)")
            check(url?.absoluteString.contains("testnet") == false, "Mainnet route for \(chain)")
            check(chain.transactionExplorerURL(hash: "") == nil, "Reject empty hash")
            check(chain.transactionExplorerURL(hash: "https://other.example/?hash") == nil, "Reject URL as hash")
        }
        check(OathImportChain.aptos.transactionExplorerURL(hash: hex)?.query == "network=mainnet", "Aptos network")
        check(OathImportChain.tron.transactionExplorerURL(hash: hex)?.fragment == "/transaction/" + hex, "TRON fragment route")
        let bytes = Data(repeating: 255, count: 32)
        check(OathImportChain.ton.transactionExplorerURL(hash: bytes.base64EncodedString())?.lastPathComponent == String(repeating: "ff", count: 32), "TON base64 path safety")
        check(OathImportChain.ton.transactionExplorerURL(hash: bytes.base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))?.lastPathComponent == String(repeating: "ff", count: 32), "TON base64url")
        check(OathImportChain.ton.transactionExplorerURL(hash: "invalid") == nil, "Invalid TON hash")
        check(OathImportChain.arc.transactionExplorerURL(hash: hex)?.host == "explorer.arc.io", "Arc mainnet")
        check(OathImportChain.robinhood.transactionExplorerURL(hash: hex)?.host == "robinhoodchain.blockscout.com", "Robinhood mainnet")
        print("Passed \(checks) explorer routing checks across \(OathImportChain.allCases.count) networks.")
    }
}
