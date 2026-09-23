import Foundation

actor SendRecipientNameResolver {
    static let shared = SendRecipientNameResolver()

    private struct CacheKey: Hashable {
        let name: String
        let networkID: String
    }

    private struct CacheEntry {
        let address: String
        let expiresAt: Date
    }

    private let ensClient: ENSUniversalResolverClient
    private let session: URLSession
    private var cache: [CacheKey: CacheEntry] = [:]

    init(
        ensClient: ENSUniversalResolverClient =
            ENSUniversalResolverClient(),
        session: URLSession? = nil
    ) {
        self.ensClient = ensClient
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func resolve(
        _ rawInput: String,
        networkID: String
    ) async throws -> String {
        guard
            let descriptor = try SendRecipientNameParser.descriptor(
                for: rawInput
            )
        else {
            throw SendRecipientNameError.invalidName
        }
        guard descriptor.candidateNetworkIDs.contains(networkID) else {
            throw SendRecipientNameError.networkMismatch
        }

        let cacheKey = CacheKey(
            name: descriptor.input.lowercased(),
            networkID: networkID
        )
        if let entry = cache[cacheKey],
           entry.expiresAt > Date(),
           SendAddressValidator.isValid(
               entry.address,
               for: networkID
           ) {
            return entry.address
        }

        let address: String
        switch descriptor.service {
        case .ens:
            address = try await ensClient.resolve(
                name: descriptor.input,
                networkID: networkID
            )
        case .solanaNameService:
            address = try await resolveSolanaName(
                descriptor.input
            )
        case .spaceIDDomain:
            address = try await resolveSpaceIDDomain(
                descriptor.input
            )
        case .spaceIDPaymentID:
            address = try await resolvePaymentID(
                descriptor.input,
                networkID: networkID
            )
        }
        guard SendAddressValidator.isValid(address, for: networkID)
        else {
            throw SendRecipientNameError.invalidResolvedAddress
        }
        cache[cacheKey] = CacheEntry(
            address: address,
            expiresAt: Date().addingTimeInterval(300)
        )
        return address
    }

    private func resolveSolanaName(
        _ name: String
    ) async throws -> String {
        do {
            return try await resolveWithSNS(name)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SendRecipientNameError {
            guard
                error == .notFound
                    || error == .serviceUnavailable
                    || error == .invalidServiceResponse
            else {
                throw error
            }
            return try await resolveSpaceIDDomain(name)
        }
    }

    private func resolveWithSNS(_ name: String) async throws -> String {
        guard let encodedName = Self.encodedPathSegment(name) else {
            throw SendRecipientNameError.invalidName
        }
        let url = URL(
            string: "https://sdk-proxy.sns.id/resolve/\(encodedName)"
        )!
        let object = try await jsonObject(from: url)
        guard
            let status = object["s"] as? String,
            let result = object["result"] as? String
        else {
            throw SendRecipientNameError.invalidServiceResponse
        }
        guard status == "ok" else {
            if result.localizedCaseInsensitiveContains("not found") {
                throw SendRecipientNameError.notFound
            }
            throw SendRecipientNameError.invalidServiceResponse
        }
        guard !result.isEmpty else {
            throw SendRecipientNameError.notFound
        }
        return result
    }

    private func resolveSpaceIDDomain(
        _ name: String
    ) async throws -> String {
        var components = URLComponents(
            string: "https://nameapi.space.id/getAddress"
        )!
        components.queryItems = [
            URLQueryItem(name: "domain", value: name)
        ]
        guard let url = components.url else {
            throw SendRecipientNameError.invalidName
        }
        return try Self.spaceIDAddress(
            from: try await jsonObject(from: url)
        )
    }

    private func resolvePaymentID(
        _ paymentID: String,
        networkID: String
    ) async throws -> String {
        guard
            let chainType = Self.paymentIDChainType(
                for: networkID
            ),
            let encodedID = Self.encodedPathSegment(paymentID)
        else {
            throw SendRecipientNameError.networkMismatch
        }
        let url = URL(
            string:
                "https://nameapi.space.id/getPaymentIdName/\(encodedID)/\(chainType)"
        )!
        return try Self.spaceIDAddress(
            from: try await jsonObject(from: url)
        )
    }

    private func jsonObject(
        from url: URL
    ) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SendRecipientNameError.serviceUnavailable
        }
        guard
            let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200,
            data.count <= 262_144
        else {
            throw SendRecipientNameError.serviceUnavailable
        }
        guard
            let object = try? JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any]
        else {
            throw SendRecipientNameError.invalidServiceResponse
        }
        return object
    }

    private static func spaceIDAddress(
        from object: [String: Any]
    ) throws -> String {
        let code: Int?
        if let integer = object["code"] as? Int {
            code = integer
        } else if let number = object["code"] as? NSNumber {
            code = number.intValue
        } else if let string = object["code"] as? String {
            code = Int(string)
        } else {
            code = nil
        }
        guard let code else {
            throw SendRecipientNameError.invalidServiceResponse
        }
        guard code == 0 else {
            throw SendRecipientNameError.notFound
        }
        guard
            let address = object["address"] as? String,
            !address.isEmpty
        else {
            throw SendRecipientNameError.invalidServiceResponse
        }
        return address
    }

    private static func paymentIDChainType(
        for networkID: String
    ) -> String? {
        if SendAddressValidator.evmNetworks.contains(
            where: { $0.id == networkID }
        ) {
            return "evm"
        }
        switch networkID {
        case BitcoinFamilyChain.bitcoin.networkID:
            return "btc"
        case SolanaConstants.networkID:
            return "sol"
        case TronConstants.networkID:
            return "tron"
        default:
            return nil
        }
    }

    private static func encodedPathSegment(
        _ value: String
    ) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(
            withAllowedCharacters: allowed
        )
    }
}
