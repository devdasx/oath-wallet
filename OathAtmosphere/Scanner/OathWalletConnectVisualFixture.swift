#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import OathAnkr

/// Public, non-signing UI fixtures. Compiled out of device/release builds.
/// Uses production views; does not configure the relay, unlock a vault, or
/// substitute successful signing/network results in the production service.
struct OathWalletConnectVisualFixture: View {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "oath.wcVisualFixture") }
    @State private var selection: String?
    @Environment(\.oathLocalizer) private var strings
    private let states = ["connect", "unverified", "blocked", "unsupported", "message", "signin", "typed", "permit", "permit2", "connected", "signed", "signedTx", "expired", "changed", "offline", "failed", "disconnected", "pairing", "send", "approve", "swap", "nft", "contract", "pending", "success", "transactionFailed", "gas", "simulation", "submitting", "thor", "deposit", "networkSwitch", "rejected", "approvalPending", "approvalDone", "sent", "networkAdd", "batch", "crossSwap", "crossPending"]
    var body: some View {
        NavigationStack {
            List(states, id: \.self) { state in
                Button(state) { selection = state }.accessibilityIdentifier("wc.fixture." + state)
            }.navigationTitle("WalletConnect UI fixtures")
        }.preferredColorScheme(UserDefaults.standard.bool(forKey: "oath.wcFixtureDark") ? .dark : .light)
        .sheet(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let selection {
                OathWCFixtureSheet(state: selection) { self.selection = nil }.oathLanguage(strings.language)
            }
        }
    }
}

private struct OathWCFixtureSheet: View {
    let state: String
    let close: @MainActor () -> Void
    @State private var wallet = "main"
    @State private var networks: Set<String> = ["eip155:1", "eip155:42161"]
    @State private var acknowledged = false
    @State private var completed = false
    @State private var editedApproval: String?
    @Environment(\.oathLocalizer) private var strings
    private let account = "0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A"
    private var identity: OathWCIdentity {
        .init(name: "Example dApp", url: "https://example.com", icons: [], origin: "https://example.com",
              verification: state == "blocked" ? .blocked : state == "unverified" ? .unknown : .matched)
    }
    private var fixtureProgress: OathWalletConnectTransactionProgress {
        var progress = OathWalletConnectTransactionProgress()
        _ = progress.update(.init(outcome: ["success", "approvalDone", "sent"].contains(state) ? .confirmed : state == "transactionFailed" ? .failed : .pending))
        return progress
    }
    var body: some View {
        NavigationStack {
            content
                .navigationTitle(strings.text(.walletConnect)).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    OathCloseButton(action: close).accessibilityIdentifier("wc.fixture.close")
                } }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
            .presentationBackground(Color(uiColor: OathSurfaceColors.canvas))
            .oathNativeLocalization()
    }
    @ViewBuilder private var content: some View {
        if ["connect", "unverified", "blocked", "unsupported", "networkAdd", "batch"].contains(state), !completed {
            OathWalletConnectConsent(identity: identity,
                wallets: [.init(id: "main", name: strings.text(.mainWalletName)), .init(id: "imported", name: strings.text(.importedWalletName))],
                networks: [
                    .init(id: "eip155:1", name: "Ethereum", logo: "network-ethereum", address: account, required: true),
                    .init(id: "eip155:42161", name: "Arbitrum", logo: "network-arbitrum", address: account, required: false)
                ], methods: [.init(id: "eip155", methods: ["personal_sign", "eth_signTypedData_v4", "eth_accounts", "eth_chainId"], events: ["accountsChanged", "chainChanged"])],
                supported: !["unsupported", "networkAdd", "batch"].contains(state), loadingAccounts: false, working: false, failed: false,
                walletID: $wallet, selected: $networks, acknowledged: $acknowledged,
                approve: { completed = true }, reject: close, close: close,
                unavailableMethods: state == "networkAdd" ? ["wallet_addEthereumChain"] : state == "batch" ? ["wallet_sendCalls"] : [])
        } else if ["message", "signin", "typed", "permit", "permit2"].contains(state) {
            OathWCContent {
                OathWCDAppHeader(identity: identity)
                if state == "message" || state == "signin" {
                    let text = state == "message" ? "Please confirm that you control this address.\nThis is a public UI test message." : Self.signInMessage(account)
                    OathWCMessageReview(message: text, signIn: state == "signin" ? Self.signIn(account) : nil,
                        account: account, network: "Ethereum", close: close)
                } else if let data = Self.typed(state, account: account) {
                    OathWalletConnectTypedReview(data: data, account: account, network: "Ethereum", close: close)
                }
            }.oathBottomActions {
                OathWCFooter {
                    // Only closes the visual fixture. Never invokes signing.
                    OathActionButton(title: strings.text(.scannerWCSign), action: close).accessibilityIdentifier("wc.fixture.sign")
                    OathButton(strings.text(.scannerWCReject), role: .destructive, action: close).foregroundStyle(.red)
                }
            }
        } else if ["send", "approve", "swap", "nft", "contract"].contains(state), let (request, plan) = Self.evm(state, account: account, approvalAmount: editedApproval) {
            OathWCContent {
                OathWCDAppHeader(identity: identity)
                OathWCEVMReview(request: request, plan: plan, close: close,
                    approvalToken: state == "approve" ? .init(contract: request.recipient, decimals: 6, balance: "250000000", allowance: "0") : nil,
                    saveLimit: { editedApproval = $0 })
            }.oathBottomActions {
                OathWCFooter {
                    OathActionButton(title: strings.text(.wcSubmitTransaction), action: close).accessibilityIdentifier("wc.fixture.sign")
                    OathButton(strings.text(.scannerWCReject), role: .destructive, action: close).foregroundStyle(.red)
                }
            }
        } else if ["thor", "deposit", "crossSwap"].contains(state), let request = Self.thor(deposit: state != "thor", swap: state == "crossSwap") {
            OathWCContent {
                OathWCDAppHeader(identity: identity)
                OathWCThorchainReview(request: request, review: .init(fee: 2_000_000, decimals: ["native": 8],
                    swap: state == "crossSwap" ? ThorchainSwapMemo(request.memo).map { .init(memo: $0, input: "250000000", expectedOutput: "61000", outboundFee: "1000", liquidityFee: "300", affiliateFee: "0", expires: .now.addingTimeInterval(600)) } : nil), close: close)
            }.oathBottomActions {
                OathWCFooter { OathActionButton(title: strings.text(.wcSignTransaction), action: close).accessibilityIdentifier("wc.fixture.sign") }
            }
        } else if state == "crossPending", let progress = Self.swapProgress {
            OathWCThorchainProgress(initial: progress, fixture: true)
        } else if state == "networkSwitch" {
            OathWCContent {
                OathWCDAppHeader(identity: identity)
                OathWCNetworkSwitchReview(current: 1, requested: 42161)
            }.oathBottomActions {
                OathWCFooter { OathActionButton(title: strings.text(.wcSwitchNetwork), action: close).accessibilityIdentifier("wc.fixture.sign") }
            }
        } else if ["pending", "success", "transactionFailed", "approvalPending", "approvalDone", "sent"].contains(state), let (request, plan) = Self.evm(state.hasPrefix("approval") ? "approve" : "send", account: account) {
            OathWCEVMCompletion(transaction: .init(sendID: "public-fixture", hash: "0x" + String(repeating: "ab", count: 32), plan: plan,
                progress: fixtureProgress, action: WalletConnectEVMAction(request),
                approvalToken: state.hasPrefix("approval") ? .init(contract: request.recipient, decimals: 6, balance: "250000000", allowance: "0") : nil), identity: identity, close: close)
        } else if state == "gas" {
            OathWCGasPage(network: "ethereum", address: account, close: close)
        } else {
            let keys = stateKeys
            OathWCStatePage(title: keys.0, detail: keys.1, symbol: keys.2, identity: identity,
                isError: keys.3, isWorking: state == "pairing" || state == "submitting", primary: close)
        }
    }
    private var stateKeys: (OathStringKey, OathStringKey, String, Bool) {
        switch state {
        case "signed": (.wcSignatureSent, .wcSignatureSentDetail, "checkmark.circle.fill", false)
        case "signedTx": (.wcTransactionSigned, .wcTransactionSignedDetail, "checkmark.circle.fill", false)
        case "expired": (.wcExpiredTitle, .wcExpiredDetail, "clock.badge.exclamationmark", true)
        case "changed": (.wcChangedTitle, .wcChangedDetail, "exclamationmark.circle", true)
        case "offline", "failed": (.wcInterruptedTitle, .wcInterruptedDetail, "wifi.exclamationmark", true)
        case "unsupported": (.wcUnsupportedTitle, .wcUnsupportedDetail, "exclamationmark.circle", true)
        case "disconnected": (.wcDisconnected, .wcDisconnectedDetail, "link", false)
        case "pairing": (.scannerWCLoading, .wcPreparingDetail, "link", false)
        case "simulation": (.wcSimulationFailed, .wcSimulationFailedDetail, "exclamationmark.circle", true)
        case "submitting": (.wcSubmitTransaction, .wcSendingDetail, "link", false)
        case "rejected": (.wcRequestDeclined, .wcRequestDeclinedDetail, "xmark.circle", false)
        default: (.scannerWCConnected, .scannerWCConnectedDetail, "checkmark.circle.fill", false)
        }
    }
    private static var swapProgress: ThorchainSwapProgress? {
        guard let request = Self.thor(deposit: true, swap: true) else { return nil }
        let hash = String(repeating: "AB", count: 32)
        let json: SolanaJSON = .object([
            "tx": .object(["id": .string(hash), "chain": .string("THOR"), "from_address": .string(request.sender),
                "memo": .string(request.memo), "coins": .array([.object(["asset": .string("THOR.RUNE"), "amount": .string("250000000")])])]),
            "stages": .object(["inbound_finalised": .object(["completed": .bool(true)]),
                "swap_finalised": .object(["completed": .bool(false)]), "outbound_signed": .object(["completed": .bool(false)])]),
            "out_txs": .array([]), "planned_out_txs": .array([])])
        return try? ThorchainSwapProgress.decode(json, hash: hash)
    }
    private static func thor(deposit: Bool, swap: Bool = false) -> ThorchainWalletConnectRequest? {
        guard let key = try? ThorchainSendCrypto.publicKey(privateKey: Data(repeating: 1, count: 32)),
              let sender = try? ThorchainSendCrypto.address(publicKey: key, network: .mainnet) else { return nil }
        let message: SolanaJSON = deposit
            ? .object(["type": .string("thorchain/MsgDeposit"), "value": .object(["signer": .string(sender), "memo": .string(swap ? "=:ETH.ETH:0x2222222222222222222222222222222222222222:60000/1/1" : "RESERVE"), "coins": .array([.object(["asset": .string("THOR.RUNE"), "amount": .string("250000000")])])])])
            : .object(["type": .string("thorchain/MsgSend"), "value": .object(["from_address": .string(sender), "to_address": .string(sender), "amount": .array([.object(["denom": .string("rune"), "amount": .string("250000000")])])])])
        let doc: SolanaJSON = .object(["chain_id": .string(ThorchainSendNetwork.mainnet.chainID), "account_number": .string("12"), "sequence": .string("4"), "fee": .object(["gas": .string("200000"), "amount": .array([])]), "memo": .string("Public UI fixture"), "msgs": .array([message])])
        return try? .init(method: "cosmos_signAmino", params: .object(["signerAddress": .string(sender), "signDoc": doc]), sender: sender, publicKey: key)
    }
    private static func evm(_ state: String, account: String, approvalAmount: String? = nil) -> (WalletConnectEVMRequest, EVMSendPlan)? {
        let recipient = "0x2222222222222222222222222222222222222222"
        func addressWord(_ value: String) -> String { String(repeating: "0", count: 24) + value.dropFirst(2).lowercased() }
        func uintWord(_ value: UInt64) -> String { let hex = String(value, radix: 16); return String(repeating: "0", count: 64 - hex.count) + hex }
        let data: String
        switch state {
        case "approve": data = "0x095ea7b3" + addressWord(recipient) + String(repeating: "f", count: 64)
        case "nft": data = "0x42842e0e" + addressWord(account) + addressWord(recipient) + uintWord(27)
        case "contract": data = "0x12345678" + uintWord(12)
        case "swap": data = "0x414bf389" + addressWord(recipient) + addressWord("0x3333333333333333333333333333333333333333") + uintWord(3000) + addressWord(account) + uintWord(2_000_000_000) + uintWord(1000000) + uintWord(990000) + uintWord(0)
        default: data = "0x"
        }
        let object = ["from": account, "to": state == "swap" ? "0xe592427a0aece92de3edee1f18e0157c05861564" : recipient,
            "value": state == "send" ? "0x2386f26fc10000" : "0x0", "data": data]
        guard let json = try? JSONSerialization.data(withJSONObject: [object]),
              var request = try? WalletConnectEVMRequest(params: json, account: account, chainID: 1) else { return nil }
        if let approvalAmount, let edited = try? request.replacingApprovalAmount(approvalAmount) { request = edited }
        let plan = EVMSendPlan(network: .ethereum, sender: request.sender, recipient: request.recipient, reference: "native", decimals: 18,
            requestedAmount: request.value, amount: request.value, assetBalance: "1000000000000000000", nativeBalance: "1000000000000000000",
            nonce: 7, gasLimit: data == "0x" ? 21000 : 60000, maxFeePerGas: 1000000000, maxPriorityFeePerGas: 1, blockHeight: 100, call: request.call)
        return (request, plan)
    }
    private static func signInMessage(_ account: String) -> String {
        "example.com wants you to sign in with your Ethereum account:\n\(account)\n\nSign in to Example dApp.\n\nURI: https://example.com/login\nVersion: 1\nChain ID: 1\nNonce: 12345678\nIssued At: 2026-10-15T08:00:00Z\nExpiration Time: 2026-10-15T08:15:00Z\nResources:\n- https://example.com/profile"
    }
    private static func signIn(_ account: String) -> WalletConnectSignIn? {
        // Static fixture dates prevent network/clock dependencies in UI tests.
        try? WalletConnectSignIn.parse(Data(signInMessage(account).utf8), account: account, chainID: 1,
            website: "https://example.com", now: Date(timeIntervalSince1970: 1_792_051_200))
    }
    private static func typed(_ state: String, account: String) -> WalletConnectTypedData? {
        let domainTypes: [[String: String]] = [["name": "name", "type": "string"], ["name": "chainId", "type": "uint256"], ["name": "verifyingContract", "type": "address"]]
        let contract = "0x1111111111111111111111111111111111111111"
        let spender = "0x2222222222222222222222222222222222222222"
        var types: [String: [[String: String]]] = ["EIP712Domain": domainTypes]
        let primary: String
        let message: [String: Any]
        if state == "permit" {
            primary = "Permit"
            types[primary] = zip(["owner", "spender", "value", "nonce", "deadline"], ["address", "address", "uint256", "uint256", "uint256"]).map { ["name": $0, "type": $1] }
            message = ["owner": account, "spender": spender, "value": "100000000", "nonce": "0", "deadline": "2000000000"]
        } else if state == "permit2" {
            primary = "PermitSingle"
            types[primary] = [["name": "details", "type": "PermitDetails"], ["name": "spender", "type": "address"], ["name": "sigDeadline", "type": "uint256"]]
            types["PermitDetails"] = zip(["token", "amount", "expiration", "nonce"], ["address", "uint160", "uint48", "uint48"]).map { ["name": $0, "type": $1] }
            message = ["details": ["token": contract, "amount": "100000000", "expiration": "2000000100", "nonce": "0"], "spender": spender, "sigDeadline": "2000000000"]
        } else {
            primary = "Review"
            types[primary] = [["name": "message", "type": "string"], ["name": "value", "type": "uint256"]]
            message = ["message": "Public typed-data UI fixture", "value": "115792089237316195423570985008687907853269984665640564039457584007913129639935"]
        }
        let json: [String: Any] = ["types": types, "primaryType": primary,
            "domain": ["name": state == "permit2" ? "Permit2" : "Example dApp", "chainId": 1, "verifyingContract": state == "permit2" ? "0x000000000022D473030F116dDEE9F6B43aC78BA3" : contract], "message": message]
        // Public static fixtures only; no request failures or secrets are ignored.
        guard let bytes = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? WalletConnectTypedData(json: bytes, chainID: 1, account: account)
    }
}
#endif
