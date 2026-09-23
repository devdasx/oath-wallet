import Foundation
import Security

enum AnkrAPIError: Error, Sendable {
    case missingConfiguration
    case invalidProxyConfiguration
    case invalidAPIKey
    case invalidWalletAddress
    case invalidContractAddress
    case unsupportedBlockchain
    case tokenNotFound
    case invalidTokenMetadata
    case invalidResponse
    case developmentCredentialPersistenceFailure(OSStatus)
    case httpFailure(statusCode: Int, message: String?)
    case rpcFailure(code: Int, message: String)

    var diagnosticDescription: String {
        switch self {
        case .missingConfiguration:
            "missing_configuration"
        case .invalidProxyConfiguration:
            "invalid_proxy_configuration"
        case .invalidAPIKey:
            "invalid_api_key"
        case .invalidWalletAddress:
            "invalid_wallet_address"
        case .invalidContractAddress:
            "invalid_contract_address"
        case .unsupportedBlockchain:
            "unsupported_blockchain"
        case .tokenNotFound:
            "token_not_found"
        case .invalidTokenMetadata:
            "invalid_token_metadata"
        case .invalidResponse:
            "invalid_response"
        case let .developmentCredentialPersistenceFailure(status):
            "development_credential_keychain_status=\(status)"
        case let .httpFailure(statusCode, message):
            if let message, !message.isEmpty {
                "http_status=\(statusCode) provider_message=\(message)"
            } else {
                "http_status=\(statusCode)"
            }
        case let .rpcFailure(code, message):
            "rpc_code=\(code) provider_message=\(message)"
        }
    }
}

struct AnkrConfiguration: Sendable {
    private enum Transport: Sendable {
        case proxy(
            multichain: URL,
            tronJSONRPC: URL,
            tronRESTBase: URL,
            solanaJSONRPC: URL?,
            xrpJSONRPC: URL?,
            nearJSONRPC: URL?
        )
#if DEBUG
        case localDevelopment(apiKey: String)
#endif
    }

    private let transport: Transport

#if DEBUG
    private static let developmentCredentialLock = NSLock()
#endif

    var usesTronRESTProxy: Bool {
        switch transport {
        case .proxy:
            true
#if DEBUG
        case .localDevelopment:
            false
#endif
        }
    }

    var multichainEndpoint: URL {
        switch transport {
        case let .proxy(multichain, _, _, _, _, _):
            multichain
#if DEBUG
        case let .localDevelopment(apiKey):
            Self.directEndpoint(path: "multichain/\(apiKey)")
#endif
        }
    }

    var tronJSONRPCEndpoint: URL {
        switch transport {
        case let .proxy(_, tronJSONRPC, _, _, _, _):
            tronJSONRPC
#if DEBUG
        case let .localDevelopment(apiKey):
            Self.directEndpoint(path: "tron_jsonrpc/\(apiKey)")
#endif
        }
    }

    var solanaJSONRPCEndpoint: URL {
        get throws {
            switch transport {
            case let .proxy(_, _, _, solanaJSONRPC, _, _):
                guard let solanaJSONRPC else {
                    throw AnkrAPIError.missingConfiguration
                }
                return solanaJSONRPC
#if DEBUG
            case let .localDevelopment(apiKey):
                return Self.directEndpoint(path: "solana/\(apiKey)")
#endif
            }
        }
    }

    var xrpJSONRPCEndpoint: URL {
        get throws {
            switch transport {
            case let .proxy(_, _, _, _, xrpJSONRPC, _):
                guard let xrpJSONRPC else {
                    throw AnkrAPIError.missingConfiguration
                }
                return xrpJSONRPC
#if DEBUG
            case let .localDevelopment(apiKey):
                return Self.directEndpoint(path: "xrp_mainnet/\(apiKey)")
#endif
            }
        }
    }

    /// The service adds the ANKR token server-side. Never embed it in the app URL.
    var suiGRPCEndpoint: URL {
        get throws {
            switch transport {
            case let .proxy(multichain, _, _, _, _, _):
                return multichain.deletingLastPathComponent().appendingPathComponent("sui/grpc")
#if DEBUG
            case .localDevelopment:
                throw AnkrAPIError.missingConfiguration
#endif
            }
        }
    }

    var nearJSONRPCEndpoint: URL {
        get throws {
            switch transport {
            case let .proxy(_, _, _, _, _, nearJSONRPC):
                guard let nearJSONRPC else {
                    throw AnkrAPIError.missingConfiguration
                }
                return nearJSONRPC
#if DEBUG
            case let .localDevelopment(apiKey):
                return Self.directEndpoint(path: "near/\(apiKey)")
#endif
            }
        }
    }

    /// Current DOT lives on Asset Hub; the relay endpoint is for legacy chain reads.
    var polkadotAssetHubJSONRPCEndpoint: URL {
        switch transport {
        case let .proxy(multichain, _, _, _, _, _):
            multichain.deletingLastPathComponent().appendingPathComponent("polkadot/asset-hub/jsonrpc")
#if DEBUG
        case let .localDevelopment(apiKey):
            Self.directEndpoint(path: "polkadot_mainnet_asset_hub/\(apiKey)")
#endif
        }
    }

    var polkadotRelayJSONRPCEndpoint: URL {
        switch transport {
        case let .proxy(multichain, _, _, _, _, _):
            multichain.deletingLastPathComponent().appendingPathComponent("polkadot/relay/jsonrpc")
#if DEBUG
        case let .localDevelopment(apiKey):
            Self.directEndpoint(path: "polkadot/\(apiKey)")
#endif
        }
    }

    func tronRESTEndpoint(path: String) throws -> URL {
        guard !path.isEmpty, !path.contains("..") else {
            throw AnkrAPIError.invalidResponse
        }
        switch transport {
        case let .proxy(_, _, tronRESTBase, _, _, _):
            return tronRESTBase.appending(
                path: path,
                directoryHint: .notDirectory
            )
#if DEBUG
        case let .localDevelopment(apiKey):
            return Self.directEndpoint(
                path: "premium-http/tron/\(apiKey)/\(path)"
            )
#endif
        }
    }

    static func runtime(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AnkrConfiguration {
        let multichainProxy = configurationURL(
            environmentKey: "ANKR_MULTICHAIN_PROXY_URL",
            bundleKey: "AnkrMultichainProxyURL",
            bundle: bundle,
            environment: environment
        )
        let tronJSONRPCProxy = configurationURL(
            environmentKey: "ANKR_TRON_JSONRPC_PROXY_URL",
            bundleKey: "AnkrTronJSONRPCProxyURL",
            bundle: bundle,
            environment: environment
        )
        let tronRESTProxyBase = configurationURL(
            environmentKey: "ANKR_TRON_REST_PROXY_BASE_URL",
            bundleKey: "AnkrTronRESTProxyBaseURL",
            bundle: bundle,
            environment: environment
        )
        let solanaJSONRPCProxy = configurationURL(
            environmentKey: "ANKR_SOLANA_JSONRPC_PROXY_URL",
            bundleKey: "AnkrSolanaJSONRPCProxyURL",
            bundle: bundle,
            environment: environment
        )
        let xrpJSONRPCProxy = configurationURL(
            environmentKey: "ANKR_XRP_JSONRPC_PROXY_URL",
            bundleKey: "AnkrXRPJSONRPCProxyURL",
            bundle: bundle,
            environment: environment
        )
        let nearJSONRPCProxy = configurationURL(
            environmentKey: "ANKR_NEAR_JSONRPC_PROXY_URL",
            bundleKey: "AnkrNEARJSONRPCProxyURL",
            bundle: bundle,
            environment: environment
        )

        if multichainProxy != nil
            || tronJSONRPCProxy != nil
            || tronRESTProxyBase != nil {
            guard let multichainProxy,
                  let tronJSONRPCProxy,
                  let tronRESTProxyBase
            else {
                throw AnkrAPIError.invalidProxyConfiguration
            }
            return AnkrConfiguration(
                transport: .proxy(
                    multichain: multichainProxy,
                    tronJSONRPC: tronJSONRPCProxy,
                    tronRESTBase: tronRESTProxyBase,
                    solanaJSONRPC: solanaJSONRPCProxy,
                    xrpJSONRPC: xrpJSONRPCProxy,
                    nearJSONRPC: nearJSONRPCProxy
                )
            )
        }

#if DEBUG
        developmentCredentialLock.lock()
        defer {
            developmentCredentialLock.unlock()
        }
        if let rawKey = environment["ANKR_API_KEY"] {
            let apiKey = try validatedAPIKey(rawKey)
            try AnkrDevelopmentCredentialStore.save(apiKey)
            return AnkrConfiguration(
                transport: .localDevelopment(apiKey: apiKey)
            )
        }

        if let storedKey = try AnkrDevelopmentCredentialStore.load() {
            return AnkrConfiguration(
                transport: .localDevelopment(
                    apiKey: try validatedAPIKey(storedKey)
                )
            )
        }
        throw AnkrAPIError.missingConfiguration
#else
        throw AnkrAPIError.missingConfiguration
#endif
    }

    private static func configurationURL(
        environmentKey: String,
        bundleKey: String,
        bundle: Bundle,
        environment: [String: String]
    ) -> URL? {
        let rawValue = environment[environmentKey]
            ?? bundle.object(forInfoDictionaryKey: bundleKey) as? String
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains("$("),
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else {
            return nil
        }
        return url
    }

#if DEBUG
    private static func validatedAPIKey(_ rawValue: String) throws -> String {
        let apiKey = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            apiKey.count >= 32,
            apiKey.unicodeScalars.allSatisfy({ scalar in
                CharacterSet.alphanumerics.contains(scalar)
            })
        else {
            throw AnkrAPIError.invalidAPIKey
        }
        return apiKey
    }

    private static func directEndpoint(path: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "rpc.ankr.com"
        components.path = "/\(path)"
        guard let url = components.url else {
            preconditionFailure("Static ANKR endpoint construction failed.")
        }
        return url
    }
#endif
}

#if DEBUG
enum AnkrDevelopmentCredentialInsertResolution: Equatable {
    case complete
    case retryUpdate
    case failure(OSStatus)

    init(status: OSStatus) {
        switch status {
        case errSecSuccess:
            self = .complete
        case errSecDuplicateItem:
            self = .retryUpdate
        default:
            self = .failure(status)
        }
    }
}

private enum AnkrDevelopmentCredentialStore {
    private static let service = WalletSecretVault.keychainService
    private static let account = "advanced-api-key"

    static func save(_ apiKey: String) throws {
        if try load() == apiKey {
            return
        }
        let keyData = Data(apiKey.utf8)
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: keyData,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var insertion = lookup
            attributes.forEach { insertion[$0.key] = $0.value }
            let insertionStatus = SecItemAdd(
                insertion as CFDictionary,
                nil
            )
            switch AnkrDevelopmentCredentialInsertResolution(
                status: insertionStatus
            ) {
            case .complete:
                break
            case .retryUpdate:
                let retryStatus = SecItemUpdate(
                    lookup as CFDictionary,
                    attributes as CFDictionary
                )
                guard retryStatus == errSecSuccess else {
                    throw AnkrAPIError
                        .developmentCredentialPersistenceFailure(
                            retryStatus
                        )
                }
            case let .failure(status):
                throw AnkrAPIError
                    .developmentCredentialPersistenceFailure(status)
            }
        } else if updateStatus != errSecSuccess {
            throw AnkrAPIError.developmentCredentialPersistenceFailure(
                updateStatus
            )
        }

        guard try load() == apiKey else {
            throw AnkrAPIError.developmentCredentialPersistenceFailure(
                errSecDecode
            )
        }
    }

    static func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let queryStatus = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        if queryStatus == errSecItemNotFound {
            return nil
        }
        guard queryStatus == errSecSuccess,
              let data = result as? Data,
              let apiKey = String(data: data, encoding: .utf8)
        else {
            throw AnkrAPIError.developmentCredentialPersistenceFailure(
                queryStatus == errSecSuccess ? errSecDecode : queryStatus
            )
        }
        return apiKey
    }
}
#endif
