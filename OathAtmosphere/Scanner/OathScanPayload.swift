import Foundation

/// Transient scan values are deliberately not Codable, Hashable, or persisted.
/// No raw scan value is ever used as a log message, URL to open, or navigation ID.
enum OathScanPayload: Sendable {
    case recipient(OathScannedRecipient)
    case recovery(OathValidatedMnemonic)
    case privateKey(String)
    case walletConnect(String)
    case invalid(OathScanProblem)
}

enum OathScanProblem: String, Error, Sendable {
    case unsupported, invalidAddress, invalidRecovery, unavailableDictionary, tooLarge, expired, unsupportedRequest
}

enum OathScannerContext: Sendable {
    case home, recipient(OathImportChain?), contact(OathImportChain?), recovery, privateKey, walletConnect

    var network: OathImportChain? {
        switch self { case .recipient(let chain), .contact(let chain): chain; default: nil }
    }

    func accepts(_ payload: OathScanPayload) -> Bool {
        if case .walletConnect = self {
            switch payload { case .walletConnect, .invalid: return true; default: return false }
        }
        return true
    }

    enum RecipientRoute: Equatable { case assets, recipient(OathImportChain), contact(OathImportChain), review }

    /// Address scans can advance without a network-selection sheet. Secrets and
    /// connections never use this route; they retain explicit consent.
    func route(_ result: OathScannedRecipient) -> RecipientRoute {
        switch self {
        case .home: return .assets
        case .recipient(let chain):
            guard let chain, result.decoded(on: chain) != nil else { return .review }
            return .recipient(chain)
        case .contact(let chain):
            guard let chain, let recipient = result.decoded(on: chain),
                  result.amount == nil, result.token == nil, recipient.memo == nil else { return .review }
            return .contact(chain)
        case .recovery, .privateKey, .walletConnect: return .review
        }
    }
}

struct OathScannedRecipient: Sendable, Equatable {
    let original: String
    let networks: [OathImportChain]
    var amount: String? = nil
    var amountIsAtomic = false
    var token: String? = nil
    var memo: String? = nil
    var memoType: String? = nil
    var label: String? = nil

    /// Reused by both the asset picker and draft application. A payment URI's
    /// token or native-amount constraint must never be discarded while filtering.
    func matchesAsset(networkID: String, reference: String) -> Bool {
        guard let chain = OathImportChain(rawValue: networkID), networks.contains(chain) else { return false }
        guard let requested = token ?? (amount == nil ? nil : "native") else { return true }
        return chain.isEVM ? reference.lowercased() == requested.lowercased() : reference == requested
    }

    func decoded(on chain: OathImportChain) -> OathScanAddress.Recipient? {
        guard networks.contains(chain), var result = OathScanAddress.decode(original, chain: chain) else { return nil }
        if let memo {
            guard result.memo == nil || result.memo == memo else { return nil }
            result.memo = memo; result.memoType = memoType
        }
        return result
    }
}

struct OathScanParser: Sendable {
    let validator: OathMnemonicValidator?
    /// Supplied by the production network catalog; no guessed EVM chain IDs.
    let evmNetworks: [UInt64: OathImportChain]

    func parse(_ raw: String, now: Date = .now) -> OathScanPayload {
        guard raw.utf8.count <= 8_192 else { return .invalid(.tooLarge) }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { $0.properties.isBidiControl || $0.value == 0 }) else { return .invalid(.unsupported) }
        if text.lowercased().hasPrefix("wc:") { return Self.walletConnect(text, now: now) }
        let words = OathMnemonicValidator.words(in: text)
        if words.count > 1 {
            guard let validator else { return .invalid(.unavailableDictionary) }
            if let phrase = validator.verifiedPhrase(text) { return .recovery(phrase) }
            return .invalid(.invalidRecovery)
        }
        // Recognize explicit secret encodings before any permissive address probe.
        if ["xprv", "yprv", "zprv", "suiprivkey1", "ed25519:", "ed25519-priv-"].contains(where: text.hasPrefix)
            || (text.count == 56 && text.hasPrefix("S"))
            || ((text.count == 51 || text.count == 52) && ["5", "K", "L", "Q", "6", "T"].contains(String(text.prefix(1)))) {
            return .privateKey(text)
        }
        // CashAddr and raw TON addresses contain colons but are not payment URLs.
        let direct = OathScanAddress.networks(for: text)
        if !direct.isEmpty { return .recipient(.init(original: text, networks: direct)) }
        if text.contains(":") { return payment(text, now: now) }
        return .invalid(.invalidAddress)
    }

    static func walletConnect(_ text: String, now: Date) -> OathScanPayload {
        guard let parts = URLComponents(string: text), parts.scheme == "wc", parts.fragment == nil,
              let at = parts.path.lastIndex(of: "@"), parts.path[parts.path.index(after: at)...] == "2",
              parts.path[..<at].count == 64, parts.path[..<at].allSatisfy(\.isHexDigit),
              let query = uniqueQuery(parts), let key = query["symKey"], key.count == 64, key.allSatisfy(\.isHexDigit),
              query["relay-protocol"] == "irn",
              Set(query.keys).isSubset(of: ["symKey", "relay-protocol", "relay-data", "expiryTimestamp"]) else { return .invalid(.unsupportedRequest) }
        if let value = query["expiryTimestamp"] {
            guard let expiry = TimeInterval(value), expiry.isFinite else { return .invalid(.unsupportedRequest) }
            if expiry <= now.timeIntervalSince1970 { return .invalid(.expired) }
        }
        return .walletConnect(text)
    }

    private func payment(_ text: String, now: Date) -> OathScanPayload {
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              parts.host == nil, parts.fragment == nil, let query = Self.uniqueQuery(parts) else { return .invalid(.unsupportedRequest) }
        let schemes: [String: OathImportChain] = ["bitcoin": .bitcoin, "bitcoincash": .bitcoincash,
            "litecoin": .litecoin, "dogecoin": .dogecoin, "solana": .solana, "tron": .tron,
            "sui": .sui, "aptos": .aptos, "near": .near, "thorchain": .thorchain, "thor": .thorchain, "ton": .ton, "xrpl": .xrpl, "xrp": .xrpl]
        var address = parts.path, network: OathImportChain?, amount = query["amount"], atomic = false
        var token = query["spl-token"], memo = query["memo"] ?? query["dt"], memoType: String?
        if scheme == "ethereum" {
            if address.hasPrefix("pay-") { address = String(address.dropFirst(4)) }
            let pieces = address.split(separator: "/", omittingEmptySubsequences: false)
            let target = pieces[0].split(separator: "@", omittingEmptySubsequences: false)
            guard !target.isEmpty, !target[0].isEmpty, target.count <= 2 else { return .invalid(.unsupportedRequest) }
            if target.count == 2 {
                guard let id = UInt64(target[1]), let chain = evmNetworks[id] else { return .invalid(.unsupportedRequest) }
                network = chain
            } else { network = .ethereum }
            address = String(target[0]); amount = query["value"]; atomic = true
            if pieces.count == 2, pieces[1] == "transfer", let recipient = query["address"], let quantity = query["uint256"] {
                token = address; address = recipient; amount = quantity
            } else if pieces.count != 1 { return .invalid(.unsupportedRequest) }
            guard Set(query.keys).isSubset(of: ["value", "address", "uint256"]),
                  token == nil || query["value"] == nil else { return .invalid(.unsupportedRequest) }
        } else if scheme == "web+stellar", address == "pay" {
            network = .stellar; address = query["destination"] ?? ""; memoType = query["memo_type"] ?? "text"
            guard Set(query.keys).isSubset(of: ["destination", "amount", "memo", "memo_type", "asset_code", "asset_issuer", "msg"]),
                  query["asset_code"] == nil || query["asset_code"] == "XLM", query["asset_issuer"] == nil,
                  ["text", "id", "hash", "return"].contains(memoType!) else { return .invalid(.unsupportedRequest) }
        } else {
            network = schemes[scheme]
            guard Set(query.keys).isSubset(of: ["amount", "label", "message", "memo", "dt", "spl-token", "text", "exp"]),
                  query["spl-token"] == nil || scheme == "solana",
                  query["text"] == nil || scheme == "ton",
                  query["dt"] == nil || scheme == "xrp" || scheme == "xrpl" else { return .invalid(.unsupportedRequest) }
            // Unsupported Solana Pay references and arbitrary transaction URLs
            // fail closed instead of silently stripping payment instructions.
            if scheme == "ton" {
                guard address.hasPrefix("transfer/") else { return .invalid(.unsupportedRequest) }
                address = String(address.dropFirst(9)); atomic = true; memo = query["text"]

            }
        }
        if let expiry = query["exp"] {
            guard let date = TimeInterval(expiry), date.isFinite else { return .invalid(.unsupportedRequest) }
            if date <= now.timeIntervalSince1970 { return .invalid(.expired) }
        }
        guard let network, OathScanAddress.decode(address, chain: network) != nil else { return .invalid(.invalidAddress) }
        if let token, OathScanAddress.decode(token, chain: network) == nil { return .invalid(.invalidAddress) }
        if let amount {
            guard amount.utf8.count <= 100, !amount.isEmpty, amount.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  amount.filter({ $0 == "." }).count <= 1, !amount.hasPrefix("."), !amount.hasSuffix("."),
                  !atomic || !amount.contains(".") else { return .invalid(.unsupportedRequest) }
        }
        if let memo {
            guard memo.utf8.count <= (network == .ton ? 120 : 128), [.xrpl, .stellar, .solana, .ton].contains(network) else { return .invalid(.unsupportedRequest) }
            if network == .xrpl || memoType == "id" {
                guard !memo.isEmpty, memo.utf8.allSatisfy({ (48...57).contains($0) }),
                      (network == .xrpl ? UInt32(memo).map { _ in true } : UInt64(memo).map { _ in true }) == true else { return .invalid(.unsupportedRequest) }
            } else if memoType == "text", memo.utf8.count > 28 { return .invalid(.unsupportedRequest) }
        }
        if network == .stellar, memoType == "hash" || memoType == "return", let value = memo {
            // SEP-7 encodes hash memos as base64; the composer stores 32-byte hex.
            guard let bytes = Data(base64Encoded: value), bytes.count == 32 else { return .invalid(.unsupportedRequest) }
            memo = bytes.map { String(format: "%02x", $0) }.joined()
            if memoType == "return" { memoType = "returnHash" }
        }
        let recipient = OathScannedRecipient(original: address, networks: [network], amount: amount, amountIsAtomic: atomic,
            token: token, memo: memo, memoType: memoType, label: query["label"] ?? query["message"] ?? query["msg"])
        guard recipient.decoded(on: network) != nil else { return .invalid(.unsupportedRequest) }
        return .recipient(recipient)
    }

    private static func uniqueQuery(_ parts: URLComponents) -> [String: String]? {
        var result: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard result[item.name] == nil, let value = item.value, value.utf8.count <= 512,
                  !value.unicodeScalars.contains(where: { $0.properties.isBidiControl || $0.value < 32 }) else { return nil }
            result[item.name] = value
        }
        return result
    }
}
