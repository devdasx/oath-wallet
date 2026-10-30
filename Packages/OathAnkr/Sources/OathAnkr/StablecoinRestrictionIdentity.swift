import Foundation

extension StablecoinRestrictionToken {
    /// Match the portfolio's actual asset identity, never its name or ticker.
    public func matchesAsset(reference candidate: String) -> Bool {
        if network == "arc", candidate == "native" { return symbol == "USDC" }
        if StablecoinRestrictionRegistry.evmIDs[network] != nil {
            return candidate.lowercased() == reference.lowercased()
        }
        switch network {
        case "stellar":
            return (try? StellarIdentity.contract(code: symbol, issuer: reference)) == candidate
        case "xrpl":
            let currency = symbol == "USDC" ? "5553444300000000000000000000000000000000" : symbol
            return (try? XrplIdentity.reference(candidate)) == currency + "." + reference
        case "aptos": return restrictionIdentityEqual(candidate, reference, using: AptosIdentity.address)
        case "ton": return restrictionIdentityEqual(candidate, reference, using: TonIdentity.raw)
        case "sui": return restrictionIdentityEqual(candidate, reference, using: SuiIdentity.reference)
        default: return candidate == reference
        }
    }
}

extension StablecoinRestrictionAccount {
    public func matchesOwner(network otherNetwork: String, address otherAddress: String) -> Bool {
        let other = PublicSigningAccount(network: otherNetwork, address: otherAddress)
        guard network == other.network else { return false }
        if StablecoinRestrictionRegistry.evmIDs[network] != nil { return address.lowercased() == other.address.lowercased() }
        switch network {
        case "aptos": return restrictionIdentityEqual(address, other.address, using: AptosIdentity.address)
        case "sui": return restrictionIdentityEqual(address, other.address, using: SuiIdentity.address)
        case "ton": return restrictionIdentityEqual(address, other.address, using: TonIdentity.raw)
        default: return address == other.address
        }
    }
}

private func restrictionIdentityEqual(_ lhs: String, _ rhs: String,
                                      using normalize: (String) throws -> String) -> Bool {
    guard let left = try? normalize(lhs), let right = try? normalize(rhs) else { return false }
    return left == right
}

extension StablecoinRestrictionCheck {
    /// Keyless endpoints for Vault. Oath's existing configured provider path is
    /// unchanged. Every adapter verifies the mainnet identity before probing.
    public static var publicMainnetEndpoints: [String: URL] {
        var endpoints = PublicSigningAuthority.evmEndpoints.compactMapValues(URL.init(string:))
        endpoints["tron"] = TronSendNetwork.mainnet.endpoint
        endpoints["solana"] = URL(string: "https://api.mainnet-beta.solana.com")
        endpoints["near"] = URL(string: "https://rpc.mainnet.near.org")
        endpoints["aptos"] = URL(string: "https://api.mainnet.aptoslabs.com/v1")
        endpoints["stellar"] = URL(string: "https://horizon.stellar.org")
        endpoints["xrpl"] = URL(string: "https://s1.ripple.com:51234")
        endpoints["sui"] = URL(string: "https://graphql.mainnet.sui.io/graphql")
        endpoints["ton"] = URL(string: "https://toncenter.com/api/v2/jsonRPC")
        return endpoints
    }

    public static func publicMainnet() -> StablecoinRestrictionCheck {
        .init(endpoints: publicMainnetEndpoints, transport: PublicRestrictionTransport())
    }
}

private struct PublicRestrictionTransport: AnkrTransport {
    private let base = AnkrHTTPTransport()
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        try Task.checkCancellation()
        var request = request
        request.setValue("OathVault/1.0", forHTTPHeaderField: "User-Agent")
        if request.url?.host == "toncenter.com" {
            try await PublicRestrictionRateLimit.shared.waitForTurn()
        }
        let result = try await base.send(request)
        try Task.checkCancellation()
        return result
    }
}

/// Pace the keyless TON provider before the initial call, without retries.
private actor PublicRestrictionRateLimit {
    static let shared = PublicRestrictionRateLimit()
    private var nextAllowed = ContinuousClock.now
    func waitForTurn() async throws {
        let scheduled = max(.now, nextAllowed)
        nextAllowed = scheduled.advanced(by: .milliseconds(1_100))
        try await Task.sleep(until: scheduled, clock: .continuous)
    }
}
