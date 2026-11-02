import OathAnkr
import OathAezeed
import OathBitcoin
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
    case unsupported, invalidAddress, invalidRecovery, unavailableDictionary, tooLarge, expired, unsupportedRequest, invalidWalletConnect, expiredWalletConnect
}

enum OathScannerContext: Sendable {
    case home, recipient(OathImportChain?), contact(OathImportChain?), recovery, privateKey, walletConnect
    case asset(OathImportChain, reference: String, symbol: String)

    var network: OathImportChain? {
        switch self {
        case .recipient(let chain), .contact(let chain): chain
        case .asset(let chain, _, _): chain
        default: nil
        }
    }

    func accepts(_ payload: OathScanPayload) -> Bool {
        if case .asset = self {
            switch payload { case .recipient, .invalid: return true; default: return false }
        }
        if case .walletConnect = self {
            switch payload { case .walletConnect, .invalid: return true; default: return false }
        }
        return true
    }

    enum RecipientRoute: Equatable { case assets, recipient(OathImportChain), contact(OathImportChain), review }

    enum Destination: Equatable { case recipient(RecipientRoute), connection, review }

    /// Pairing opens the connection proposal; only its Connect button grants
    /// the requested account/network permissions.
    func destination(for payload: OathScanPayload) -> Destination {
        guard accepts(payload) else { return .review }
        switch payload {
        case .walletConnect: return .connection
        case .recipient(let recipient):
            let route = route(recipient)
            return route == .review ? .review : .recipient(route)
        default: return .review
        }
    }

    /// Address scans can advance without a network-selection sheet. Secrets and
    /// connections never use this route; they retain explicit consent.
    func route(_ result: OathScannedRecipient) -> RecipientRoute {
        switch self {
        case .home: return .assets
        case .asset(let chain, let reference, let symbol):
            guard result.matchesAsset(networkID: chain.id, reference: reference, symbol: symbol),
                  result.decoded(on: chain) != nil else { return .review }
            return .recipient(chain)
        case .recipient(let chain):
            guard let chain, result.decoded(on: chain) != nil else { return .review }
            return .recipient(chain)
        case .contact(let chain):
            guard let chain, let recipient = result.decoded(on: chain),
                  result.amount == nil, result.token == nil || result.token == "native", result.tokenSymbol == nil, recipient.memo == nil, result.solanaReferences.isEmpty, result.displayNote == nil else { return .review }
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
    /// Legacy exchange links omit the asset. Apply units only after the user selects it.
    var amountAssetUnspecified = false
    var token: String? = nil
    /// A ticker-only URI is a selection hint, never a guessed token contract or network.
    var tokenSymbol: String? = nil
    var memo: String? = nil
    var memoType: String? = nil
    var solanaReferences: [String] = []
    var label: String? = nil
    var message: String? = nil
    var displayNote: String? {
        let fields = [label, message].compactMap { $0 }.filter { !$0.isEmpty }
        return fields.isEmpty ? nil : fields.joined(separator: "\n")
    }

    /// A symbol or address shape alone cannot identify an asset or its network.
    var hasExactAsset: Bool {
        networks.count == 1 && tokenSymbol == nil && !amountAssetUnspecified
            && (token != nil || amount != nil || networks.first?.supportsTokens == false)
    }

    /// Reused for picker promotion and amount application. A payment quantity
    /// belongs only to the requested asset; ticker-only links remain hints.
    func matchesAsset(networkID: String, reference: String, symbol: String? = nil) -> Bool {
        guard let chain = OathImportChain(rawValue: networkID), networks.contains(chain) else { return false }
        if let tokenSymbol {
            // The catalog calls Binance-bridged USDT BSC-USD. Recognize its
            // exact contract; never infer identity from a token's display name.
            if tokenSymbol == "USDT", chain == .bnb,
               reference.lowercased() == "0x55d398326f99059ff775485246999027b3197955" { return true }
            return symbol?.caseInsensitiveCompare(tokenSymbol) == .orderedSame
        }
        guard let requested = token ?? (amount == nil || amountAssetUnspecified ? nil : "native") else { return true }
        if chain == .arc, requested.lowercased() == ArcIdentity.usdc, reference == "native" { return true }
        if chain == .ton, requested != "native" {
            guard let candidate = try? TonIdentity.raw(reference), let target = try? TonIdentity.raw(requested) else { return false }
            return candidate == target
        }
        return chain.isEVM ? reference.lowercased() == requested.lowercased() : reference == requested
    }

    func atomicAmountDecimals(networkID: String, assetDecimals: Int) -> Int {
        // Arc's USDC ERC-20 interface uses six decimals for the same balance
        // represented by the native 18-decimal holding. Other contracts keep
        // their own metadata scale, even when their ticker is also USDC.
        networkID == "arc" && token?.lowercased() == ArcIdentity.usdc ? 6 : assetDecimals
    }

    /// Stable partition: preserve portfolio order inside the matching and other
    /// compatible assets when the request still needs asset selection.
    func prioritized<T>(_ assets: [T], network: (T) -> String, reference: (T) -> String, symbol: (T) -> String) -> [T] {
        let compatible = assets.filter { asset in networks.contains(where: { $0.id == network(asset) }) }
        return compatible.filter { matchesAsset(networkID: network($0), reference: reference($0), symbol: symbol($0)) }
            + compatible.filter { !matchesAsset(networkID: network($0), reference: reference($0), symbol: symbol($0)) }
    }

    func decoded(on chain: OathImportChain) -> OathScanAddress.Recipient? {
        guard networks.contains(chain), var result = OathScanAddress.decode(original, chain: chain) else { return nil }
        if let memo {
            guard result.memo == nil || result.memo == memo,
                  result.memo == nil || memoType == nil || result.memoType == memoType else { return nil }
            result.memo = memo; result.memoType = memoType ?? result.memoType
        }
        return result
    }
}

struct OathScanParser: Sendable {
    let validator: OathMnemonicValidator?
    /// Supplied by the production network catalog; no guessed EVM chain IDs.
    let evmNetworks: [UInt64: OathImportChain]

    static let paymentSchemes: [String: OathImportChain] = {
        var schemes = Dictionary(uniqueKeysWithValues: OathImportChain.allCases.map { ($0.rawValue, $0) })
        for (alias, chain) in ["eth": OathImportChain.ethereum, "btc": .bitcoin, "bch": .bitcoincash, "ltc": .litecoin,
                               "doge": .dogecoin, "bsc": .bnb, "sol": .solana, "trx": .tron,
                               "apt": .aptos, "xlm": .stellar, "xrp": .xrpl, "gram": .ton, "thor": .thorchain, "rune": .thorchain] {
            schemes[alias] = chain
        }
        return schemes
    }()

    // iOS registrations are finite. The in-app scanner also accepts other
    // ticker requests without treating a ticker as proof of token identity.
    static let registeredPaymentSchemes = Set(paymentSchemes.keys).union(["web+stellar", "usdt", "usdc", "dai"])

    func parse(_ raw: String, now: Date = .now) -> OathScanPayload {
        guard raw.utf8.count <= 8_192 else { return .invalid(.tooLarge) }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { $0.properties.isBidiControl || $0.value == 0 }) else { return .invalid(.unsupported) }
        if text.lowercased().hasPrefix("oathwallet:"), let url = URL(string: text) {
            switch OathWalletLink.parse(url, now: now, evmNetworks: evmNetworks) {
            case .payment(let recipient): return .recipient(recipient)
            case .pair(let uri): return .walletConnect(uri)
            default: return .invalid(.unsupportedRequest)
            }
        }
        if text.lowercased().hasPrefix("wc:") { return Self.walletConnect(text, now: now) }
        // Some exchanges encode an address plus a query without a URI scheme.
        // Keep the missing asset/network unresolved until the user selects it.
        if let separator = text.firstIndex(of: "?") {
            let address = String(text[..<separator])
            let networks = OathScanAddress.networks(for: address)
            if !networks.isEmpty {
                if address.lowercased().hasPrefix("bitcoincash:") { return payment(text, now: now) }
                return addressPayment(address, networks: networks, query: String(text[separator...]), now: now)
            }
        }
        // URI punctuation cannot occur in a bare WIF or Stellar secret key.
        let isBareEncoding = !text.contains(":") && !text.contains("?")
        if ["xprv", "yprv", "zprv", "suiprivkey1", "ed25519:", "ed25519-priv-"].contains(where: text.hasPrefix)
            || (isBareEncoding && text.count == 56 && text.hasPrefix("S"))
            || (isBareEncoding && (text.count == 51 || text.count == 52) && ["5", "K", "L", "Q", "6", "T"].contains(String(text.prefix(1)))) {
            return .privateKey(text)
        }
        // CashAddr and raw TON addresses contain colons but are not payment URLs.
        let direct = OathScanAddress.networks(for: text)
        if !direct.isEmpty { return .recipient(.init(original: text, networks: direct)) }
        if text.contains(":") { return payment(text, now: now) }
        let words = OathMnemonicValidator.words(in: text)
        if words.count > 1 {
            // Preserve BIP39 normalization on overlaps. The import page resolves
            // Electrum format selection and seed extensions; scanning never derives secrets.
            if Aezeed.recognizes(text) { return .recovery(.init(phrase: Aezeed.canonical(text), language: "english")) }
            if let phrase = validator?.verifiedPhrase(text) { return .recovery(phrase) }
            if ElectrumMnemonic.recognizesScannedPhrase(text) { return .recovery(.init(phrase: text, language: "electrum")) }
            guard validator != nil else { return .invalid(.unavailableDictionary) }
            return .invalid(.invalidRecovery)
        }
        return .invalid(.invalidAddress)
    }

    private func addressPayment(_ address: String, networks: [OathImportChain], query suffix: String, now: Date) -> OathScanPayload {
        guard let parts = URLComponents(string: "payment:" + suffix), parts.fragment == nil,
              let query = Self.uniqueQuery(parts),
              Set(query.keys).isSubset(of: ["amount", "label", "message", "memo", "dt", "exp"]),
              query["memo"] == nil || query["dt"] == nil else { return .invalid(.unsupportedRequest) }
        let amount = query["amount"].flatMap { Self.normalizedAmount($0, atomic: false) }
        guard query["amount"] == nil || amount != nil else { return .invalid(.unsupportedRequest) }
        if let expiry = query["exp"] {
            guard let timestamp = TimeInterval(expiry), timestamp.isFinite else { return .invalid(.unsupportedRequest) }
            if timestamp <= now.timeIntervalSince1970 { return .invalid(.expired) }
        }
        let memo = query["memo"] ?? query["dt"]
        let compatible = networks.filter { chain in
            guard query["dt"] == nil || chain == .xrpl,
                  Self.validMemo(memo, type: nil, network: chain) else { return false }
            return OathScannedRecipient(original: address, networks: [chain], memo: memo).decoded(on: chain) != nil
        }
        guard !compatible.isEmpty else { return .invalid(.unsupportedRequest) }
        return .recipient(.init(original: address, networks: compatible, amount: amount,
            amountAssetUnspecified: compatible.contains(where: \.supportsTokens), memo: memo,
            label: query["label"], message: query["message"]))
    }

    static func walletConnect(_ text: String, now: Date) -> OathScanPayload {
        guard text.utf8.count <= 8_192,
              let parts = URLComponents(string: text), parts.scheme == "wc", parts.fragment == nil,
              parts.host == nil, parts.user == nil, parts.password == nil, parts.port == nil,
              let at = parts.path.lastIndex(of: "@"), parts.path[parts.path.index(after: at)...] == "2",
              parts.path[..<at].count == 64, parts.path[..<at].allSatisfy(\.isHexDigit),
              let query = uniqueQuery(parts), let key = query["symKey"], key.count == 64, key.allSatisfy(\.isHexDigit),
              query["relay-protocol"] == "irn",
              Set(query.keys).isSubset(of: ["symKey", "relay-protocol", "relay-data", "expiryTimestamp", "methods"]) else { return .invalid(.invalidWalletConnect) }
        if let methods = query["methods"] {
            guard !methods.isEmpty, methods.utf8.count <= 1_024,
                  methods.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                      || [44, 91, 93, 95].contains($0) }) else { return .invalid(.invalidWalletConnect) }
        }
        if let value = query["expiryTimestamp"] {
            guard let expiry = UInt64(value) else { return .invalid(.invalidWalletConnect) }
            if Double(expiry) <= now.timeIntervalSince1970 { return .invalid(.expiredWalletConnect) }
        }
        return .walletConnect(text)
    }

    private func payment(_ text: String, now: Date) -> OathScanPayload {
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              parts.fragment == nil, parts.user == nil, parts.password == nil, parts.port == nil,
              parts.host == nil || (Self.paymentSchemes[scheme] == .ton && parts.host == "transfer"),
              let query = Self.uniqueQuery(parts, repeatable: ["solana", "sol"].contains(scheme) ? ["reference"] : [],
                allowValueless: ["bitcoin", "btc", "bitcoincash", "bch", "litecoin", "ltc", "dogecoin", "doge"].contains(scheme),
                bitcoin: ["bitcoin", "btc"].contains(scheme)) else { return .invalid(.unsupportedRequest) }
        let schemes = Self.paymentSchemes
        // Exchange QRs such as usdt:<address>?amount=200 identify a ticker,
        // not a contract or network. Retain all compatible token networks.
        if schemes[scheme] == nil, scheme != "ethereum", scheme != "web+stellar" {
            guard !["http", "https", "data", "file", "javascript", "mailto", "wc", "oathwallet"].contains(scheme),
                  (2...12).contains(scheme.count), scheme.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }),
                  Set(query.keys).isSubset(of: ["amount", "label", "message"]),
                  query["amount"] == nil || Self.normalizedAmount(query["amount"]!, atomic: false) != nil else { return .invalid(.unsupportedRequest) }
            let networks = OathScanAddress.networks(for: parts.path).filter(\.supportsTokens)
            guard !networks.isEmpty else { return .invalid(.invalidAddress) }
            return .recipient(.init(original: parts.path, networks: networks, amount: query["amount"].flatMap { Self.normalizedAmount($0, atomic: false) },
                                    tokenSymbol: scheme.uppercased(), label: query["label"], message: query["message"]))
        }
        guard query["memo"] == nil || query["dt"] == nil else { return .invalid(.unsupportedRequest) }
        var address = parts.host == "transfer" ? "transfer" + parts.path : parts.path
        if ["bitcoin", "btc"].contains(scheme) {
            // BIP-321 can put on-chain alternatives in repeated bc parameters.
            // Preserve an explicit path; otherwise use the first supported address.
            let alternatives = (parts.queryItems ?? []).filter { $0.name.lowercased() == "bc" }.compactMap(\.value)
            guard alternatives.count <= 16, alternatives.allSatisfy({
                $0.lowercased().hasPrefix("bc1") && OathScanAddress.decode($0, chain: .bitcoin) != nil
            }) else { return .invalid(.invalidAddress) }
            if address.isEmpty, let first = alternatives.first { address = first }
        }
        var network: OathImportChain?, unspecifiedEVMNetwork = false, amount = query["amount"], atomic = false, amountAssetUnspecified = false
        let references = (parts.queryItems ?? []).filter { $0.name == "reference" }.compactMap(\.value)
        guard references.count <= 8, references.allSatisfy(SolanaIdentity.isAddress) else { return .invalid(.unsupportedRequest) }
        var token = query["spl-token"], memo = query["memo"] ?? query["dt"], memoType: String?
        if scheme == "ethereum" || schemes[scheme]?.isEVM == true && (parts.path.contains("@") || parts.path.contains("/") || query["value"] != nil) {
            if address.hasPrefix("pay-") { address = String(address.dropFirst(4)) }
            let pieces = address.split(separator: "/", omittingEmptySubsequences: false)
            let target = pieces[0].split(separator: "@", omittingEmptySubsequences: false)
            guard !target.isEmpty, !target[0].isEmpty, target.count <= 2 else { return .invalid(.unsupportedRequest) }
            if target.count == 2 {
                guard let id = UInt64(target[1]), let chain = evmNetworks[id] else { return .invalid(.unsupportedRequest) }
                guard scheme == "ethereum" || schemes[scheme] == chain else { return .invalid(.unsupportedRequest) }
                network = chain
            } else { network = schemes[scheme] ?? .ethereum; unspecifiedEVMNetwork = scheme == "ethereum" }
            address = String(target[0]); amount = query["value"]; atomic = true
            if pieces.count == 2, pieces[1] == "transfer", let recipient = query["address"] {
                token = address; address = recipient; amount = query["uint256"]
            } else if pieces.count != 1 { return .invalid(.unsupportedRequest) }
            let feeKeys: Set<String> = ["gas", "gasLimit", "gasPrice"]
            guard feeKeys.allSatisfy({ query[$0] == nil || Self.normalizedAmount(query[$0]!, atomic: true, scientific: true) != nil }),
                  query["gas"] == nil || query["gasLimit"] == nil,
                  Set(query.keys).subtracting(feeKeys).isSubset(of: token == nil ? ["value", "amount", "label", "message"] : ["address", "uint256", "label", "message"]),
                  token == nil || query["value"] == nil,
                  query["amount"] == nil || query["value"] == nil else { return .invalid(.unsupportedRequest) }
            if token == nil, let legacyAmount = query["amount"] {
                amount = legacyAmount; atomic = false; amountAssetUnspecified = true
            }
        } else if scheme == "web+stellar", address == "pay" {
            network = .stellar; address = query["destination"] ?? ""
            let requestedMemoType = query["memo_type"] ?? "text"
            memoType = ["MEMO_TEXT": "text", "MEMO_ID": "id", "MEMO_HASH": "hash", "MEMO_RETURN": "return"][requestedMemoType] ?? requestedMemoType
            guard Set(query.keys).isSubset(of: ["destination", "amount", "memo", "memo_type", "asset_code", "asset_issuer", "msg", "network_passphrase"]),
                  query["network_passphrase"] == nil || query["network_passphrase"] == "Public Global Stellar Network ; September 2015",
                  ["text", "id", "hash", "return"].contains(memoType!) else { return .invalid(.unsupportedRequest) }
            if let issuer = query["asset_issuer"] {
                // Invalid URI fields are expected input validation, never diagnostic payloads.
                guard let code = query["asset_code"], let reference = try? StellarIdentity.contract(code: code, issuer: issuer) else { return .invalid(.unsupportedRequest) }
                token = reference
            } else if let code = query["asset_code"], code != "XLM" { return .invalid(.unsupportedRequest) }
        } else {
            network = schemes[scheme]
            // BIP-21 optional extensions may be ignored, but never required
            // fields or fields carrying a different asset or transfer action.
            let optionalUTXO = network.flatMap { UTXONetwork(rawValue: $0.rawValue) } != nil &&
                !query.keys.contains(where: { $0.hasPrefix("req-") || ["text", "memo", "dt", "spl-token", "jetton", "token", "asset", "chain", "network", "value"].contains($0) })
            guard (optionalUTXO || Set(query.keys).isSubset(of: ["amount", "label", "message", "memo", "dt", "spl-token", "text", "exp", "jetton", "reference"])),
                  references.isEmpty || network == .solana,
                  query["jetton"] == nil || network == .ton,
                  network != .ton || query["memo"] == nil,
                  query["spl-token"] == nil || network == .solana,
                  query["text"] == nil || network == .ton,
                  query["dt"] == nil || scheme == "xrp" || scheme == "xrpl" else { return .invalid(.unsupportedRequest) }
            // Remote transaction URLs require a separate contract review path.
            if network == .ton {
                guard address.hasPrefix("transfer/") else { return .invalid(.unsupportedRequest) }
                address = String(address.dropFirst(9)); atomic = true; memo = query["text"]; token = query["jetton"]

            }
        }
        if let expiry = query["exp"] {
            guard let date = TimeInterval(expiry), date.isFinite else { return .invalid(.unsupportedRequest) }
            if date <= now.timeIntervalSince1970 { return .invalid(.expired) }
        }
        guard let network, OathScanAddress.decode(address, chain: network) != nil else { return .invalid(.invalidAddress) }
        if let token, network != .stellar, OathScanAddress.decode(token, chain: network) == nil { return .invalid(.invalidAddress) }
        if let value = amount {
            guard let normalized = Self.normalizedAmount(value, atomic: atomic, scientific: network.isEVM && atomic) else { return .invalid(.unsupportedRequest) }
            amount = normalized
        }
        guard Self.validMemo(memo, type: memoType, network: network) else { return .invalid(.unsupportedRequest) }
        if network == .stellar, memoType == "hash" || memoType == "return", let value = memo {
            // SEP-7 encodes hash memos as base64; the composer stores 32-byte hex.
            guard let bytes = Data(base64Encoded: value), bytes.count == 32 else { return .invalid(.unsupportedRequest) }
            memo = bytes.map { String(format: "%02x", $0) }.joined()
            if memoType == "return" { memoType = "returnHash" }
        }
        let recipient = OathScannedRecipient(original: address, networks: unspecifiedEVMNetwork ? OathImportChain.allCases.filter(\.isEVM) : [network], amount: amount, amountIsAtomic: atomic, amountAssetUnspecified: amountAssetUnspecified,
            token: token ?? (amountAssetUnspecified ? nil : "native"), memo: memo, memoType: memoType, solanaReferences: references, label: query["label"], message: query["message"] ?? query["msg"])
        guard recipient.decoded(on: network) != nil else { return .invalid(.unsupportedRequest) }
        return .recipient(recipient)
    }

    private static func validMemo(_ memo: String?, type: String?, network: OathImportChain) -> Bool {
        guard let memo else { return true }
        guard [.xrpl, .stellar, .solana, .ton, .thorchain].contains(network),
              memo.utf8.count <= (network == .ton ? 120 : network == .thorchain ? 250 : 128) else { return false }
        if network == .xrpl || type == "id" {
            return !memo.isEmpty && memo.utf8.allSatisfy({ (48...57).contains($0) })
                && (network == .xrpl ? UInt32(memo).map { _ in true } : UInt64(memo).map { _ in true }) == true
        }
        return network != .stellar || (type != nil && type != "text") || memo.utf8.count <= 28
    }

    static func normalizedAmount(_ value: String, atomic: Bool, scientific: Bool = false) -> String? {
        guard !value.isEmpty, value.utf8.count <= 100 else { return nil }
        let unsigned = scientific && value.hasPrefix("+") ? String(value.dropFirst()) : value
        let components = unsigned.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        guard components.count == 1 || (scientific && components.count == 2) else { return nil }
        var mantissa = String(components[0])
        if !atomic, mantissa.contains(where: { $0.isASCII && $0.isNumber }) {
            if mantissa.hasPrefix(".") { mantissa = "0" + mantissa }
            if mantissa.hasSuffix(".") { mantissa += "0" }
        }
        guard !mantissa.isEmpty, !mantissa.hasPrefix("."), !mantissa.hasSuffix("."),
              mantissa.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              mantissa.filter({ $0 == "." }).count <= 1 else { return nil }
        if components.count == 1, !atomic { return mantissa }
        var exponent = 0
        if components.count == 2 {
            let sign = components[1].hasPrefix("-") ? -1 : 1
            let text = components[1].hasPrefix("+") || components[1].hasPrefix("-") ? components[1].dropFirst() : components[1][...]
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = Int(text), parsed <= 100 else { return nil }
            exponent = sign * parsed
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = parts.count == 2 ? parts[1].count : 0
        var digits = mantissa.replacingOccurrences(of: ".", with: "")
        let shift = exponent - fraction
        if shift >= 0 { digits += String(repeating: "0", count: shift) }
        else {
            guard -shift <= digits.count, digits.suffix(-shift).allSatisfy({ $0 == "0" }) else { return nil }
            digits = String(digits.dropLast(-shift))
        }
        guard digits.count <= 100 else { return nil }
        let canonical = digits.drop(while: { $0 == "0" })
        return canonical.isEmpty ? "0" : String(canonical)
    }

    private static func uniqueQuery(_ parts: URLComponents, repeatable: Set<String> = [], allowValueless: Bool = false, bitcoin: Bool = false) -> [String: String]? {
        var result: [String: String] = [:]
        let singleton: Set<String> = ["amount", "label", "message", "pop", "exp", "value", "memo", "dt", "text", "token", "asset", "chain", "network"]
        guard (parts.queryItems?.count ?? 0) <= 64 else { return nil }
        for item in parts.queryItems ?? [] {
            let key = bitcoin ? item.name.lowercased() : item.name
            let optionalBitcoin = bitcoin && !singleton.contains(key) && !key.hasPrefix("req-")
            guard result[key] == nil || repeatable.contains(key) || optionalBitcoin,
                  let value = item.value ?? (allowValueless ? "" : nil), value.utf8.count <= (optionalBitcoin ? 8_192 : 512),
                  !value.unicodeScalars.contains(where: { $0.properties.isBidiControl || CharacterSet.controlCharacters.contains($0) }) else { return nil }
            result[key] = value
        }
        return result
    }
}
