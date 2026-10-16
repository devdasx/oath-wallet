import Foundation
import OathAnkr
#if canImport(WalletConnectSign)
@preconcurrency import WalletConnectSign
#endif

/// A QR/session never grants blanket signing permission. Only methods with a
/// complete review + authorization path are negotiated; unknown required
/// methods reject the proposal instead of promising an unimplemented signer.
enum OathWalletConnectPolicy {
    /// Connection settlement and signing consent are separate steps. The same
    /// peer may immediately request sign-in while its Connected page is open.
    /// This only routes a request to review; it never authorizes a signature.
    enum RequestPresentation: Equatable {
        case idle, committingConnection, reviewing, completed
        case connected(topic: String)

        func defersRequest(topic: String, requiresApproval: Bool) -> Bool {
            // Until the approved session is associated with its local wallet,
            // even account discovery must stay in the SDK's pending queue.
            if self == .committingConnection { return true }
            guard requiresApproval else { return false }
            switch self {
            case .idle: return false
            case .connected(let connectedTopic): return topic != connectedTopic
            case .committingConnection, .reviewing, .completed: return true
            }
        }
    }
    static let approvalMethods: Set<String> = Set(["personal_sign", "eth_signTypedData_v4", "eth_sendTransaction",
        "wallet_switchEthereumChain", "cosmos_signAmino", "cosmos_signDirect"]).union(WalletConnectSolanaRequest.signingMethods)

    static func requiresFreshPairing(_ error: Error) -> Bool {
        // The pinned SDK's private error cannot be named outside its module.
        // Match its domain/code, never a message containing the pairing secret.
        let value = error as NSError
        return value.domain == "WalletConnectPairing.WalletPairService.Errors" && value.code == 0
    }
    static let methods: Set<String> = ["personal_sign", "eth_signTypedData_v4", "eth_sendTransaction", "wallet_switchEthereumChain", "eth_accounts", "eth_requestAccounts", "eth_chainId"]
    static let events: Set<String> = ["accountsChanged", "chainChanged"]
    /// A namespace's methods apply to all of its accounts. Offer only networks
    /// whose complete request path exists, rather than removing transaction
    /// permission from every EVM chain when an optional network is unsupported.
    /// Arc's separate USDC-gas sender is not a WalletConnect transaction adapter.
    static let transactionChains = Set(EVMSendNetwork.allCases.filter { !$0.isTestnet }
        .map { "eip155:\($0.chainID)" })
    static func supportsConnection(_ blockchain: String) -> Bool {
        transactionChains.contains(blockchain) || blockchain == ThorchainWalletConnectRequest.blockchain || SolanaSendNetwork(walletConnectChain: blockchain) != nil
    }
    static func methods(namespace: String) -> Set<String> {
        switch namespace {
        case "eip155": return methods
        case "solana": return WalletConnectSolanaRequest.methods
        case "cosmos": return ThorchainWalletConnectRequest.methods
        default: return []
        }
    }
    static func displayName(_ text: String) -> String {
        displayText(text, limit: 80)
    }
    static func displayText(_ text: String, limit: Int = 1_000) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(8_192)
            .filter { !$0.properties.isBidiControl && !$0.properties.isDefaultIgnorableCodePoint && $0.value >= 32 && $0.value != 127 }
            .prefix(limit)))
    }
    /// Metadata is supplied by the peer. Only an ordinary public HTTPS website
    /// may open in the browser or be fetched as artwork; never a deep link.
    static func website(_ value: String) -> URL? {
        guard value.utf8.count <= 2_048,
              !value.unicodeScalars.contains(where: { $0.properties.isBidiControl || $0.value < 32 || $0.value == 127 }),
              let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), host.utf8.allSatisfy({ $0 < 128 }),
              host.contains("."), !host.hasSuffix("."), !host.contains(":"),
              host.range(of: "^[0-9.]+$", options: .regularExpression) == nil,
              !["localhost", "local", "internal", "home", "lan"].contains(host.split(separator: ".").last.map(String.init) ?? ""),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { return nil }
        return parts.url
    }
    static func iconSources(_ icons: [String]) -> [String] {
        // Missing/invalid optional metadata is expected, not a diagnostic error.
        var result = [String]()
        for icon in icons.prefix(8) {
            guard let url = website(icon)?.absoluteString, !result.contains(url) else { continue }
            result.append(url)
            if result.count == 4 { break }
        }
        return result
    }
    static func safeHost(_ url: String) -> String? {
        website(url)?.host?.lowercased()
    }
    static func personalMessage(_ params: [String], account: String) -> Data? {
        guard params.count == 2, params[1].lowercased() == account.lowercased(), params[0].hasPrefix("0x") else { return nil }
        let raw = params[0].dropFirst(2)
        guard raw.count <= 8_192, raw.count % 2 == 0, raw.allSatisfy(\.isHexDigit) else { return nil }
        let bytes = Array(raw.utf8)
        var data = Data()
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let byte = UInt8(String(decoding: bytes[index..<index+2], as: UTF8.self), radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }
}

#if canImport(WalletConnectSign)
extension OathWalletConnectPolicy {
    /// Shared by consent preview and final approval. Unsupported optional chains
    /// are omitted; unsupported required chains/methods fail SDK validation.
    /// Existing sessions are never silently upgraded to broader permissions.
    static func namespaces(for proposal: Session.Proposal, accounts: [Account]) throws -> [String: SessionNamespace] {
        let approved = accounts.filter { supportsConnection($0.blockchain.absoluteString) }
        for (key, value) in proposal.requiredNamespaces {
            let name = String(key.prefix(while: { $0 != ":" }))
            guard value.methods.isSubset(of: methods(namespace: name)) else {
                throw AutoNamespacesError.requiredMethodsNotSatisfied
            }
            guard value.events.isSubset(of: ["eip155", "solana"].contains(name) ? events : []) else {
                throw AutoNamespacesError.requiredEventsNotSatisfied
            }
        }
        var result = try AutoNamespaces.build(sessionProposal: proposal,
            chains: Array(Set(approved.map(\.blockchain))),
            methods: Array(methods.union(ThorchainWalletConnectRequest.methods).union(WalletConnectSolanaRequest.methods)),
            events: Array(events), accounts: approved)
        // AutoNamespaces takes a global list. Never grant Cosmos methods to an
        // EVM account (or vice versa), even when the peer lists them as optional.
        let requiredGroups = Set(proposal.requiredNamespaces.keys.map { String($0.prefix(while: { $0 != ":" })) })
        for key in Array(result.keys) {
            let name = String(key.prefix(while: { $0 != ":" }))
            guard var namespace = result[key] else { continue }
            namespace.methods.formIntersection(methods(namespace: name))
            if !["eip155", "solana"].contains(name) { namespace.events = [] }
            if namespace.methods.isEmpty && !requiredGroups.contains(name) {
                result.removeValue(forKey: key)
            } else { result[key] = namespace }
        }
        guard !result.isEmpty else { throw AutoNamespacesError.emptySessionNamespacesForbidden }
        return result
    }
}
#endif
