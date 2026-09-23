import ENSNormalize
import Foundation
import WalletCore

final class ENSUniversalResolverClient: @unchecked Sendable {
    static let mainnetUniversalResolver =
        "0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe"

    private static let resolveSelector = Data(
        [0x90, 0x61, 0xb9, 0x23]
    )
    private static let multichainAddressSelector = Data(
        [0xf1, 0xcb, 0x7e, 0x06]
    )
    private static let offchainLookupSelector = Data(
        [0x55, 0x6f, 0x18, 0x30]
    )

    private static let defaultEndpoints = [
        URL(string: "https://ethereum-rpc.publicnode.com")!,
        URL(string: "https://eth.drpc.org")!,
        URL(string: "https://rpc.mevblocker.io")!
    ]
    private static let serviceID = "send_ens_mainnet_read"
    private static let requestTimeoutSeconds = 8.0

    private let endpoints: [URL]
    private let session: URLSession

    init(
        endpoint: URL? = nil,
        fallbackEndpoints: [URL] = [],
        session: URLSession? = nil
    ) {
        if let endpoint {
            endpoints = Self.uniqueEndpoints(
                [endpoint] + fallbackEndpoints
            )
        } else {
            endpoints = Self.defaultEndpoints
        }
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 20
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func resolve(
        name: String,
        networkID: String
    ) async throws -> String {
        let normalized = try Self.normalizedName(name)
        guard let coinType = ENSAddressCodec.coinType(
            for: networkID
        ) else {
            throw SendRecipientNameError.networkMismatch
        }
        let callData = try Self.resolveCallData(
            normalizedName: normalized,
            coinType: coinType
        )
        let attempts = endpoints.enumerated().map { priority, endpoint in
            let route = AdaptiveProviderEndpoint(
                serviceID: Self.serviceID,
                endpointURL: endpoint,
                baselinePriority: priority
            )
            return AdaptiveProviderAttempt(endpoint: route) { [self] in
                let result = try await ethCall(
                    to: Self.mainnetUniversalResolver,
                    data: callData,
                    depth: 0,
                    endpoint: endpoint
                )
                let record = try Self.decodeResolvedRecord(result)
                guard !record.isEmpty else {
                    throw SendRecipientNameError.noRecordForNetwork
                }
                return try ENSAddressCodec.address(
                    from: record,
                    networkID: networkID
                )
            }
        }
        return try await AdaptiveProviderRouter.shared.executeRead(
            serviceID: Self.serviceID,
            attempts: attempts,
            timeoutSeconds: Self.requestTimeoutSeconds,
            shouldFallback: Self.shouldFallback
        )
    }

    static func normalizedName(_ name: String) throws -> String {
        do {
            let normalized = try name.ensNormalized()
            guard
                normalized.utf8.count <= 255,
                normalized.lowercased().hasSuffix(".eth")
            else {
                throw SendRecipientNameError.invalidName
            }
            return normalized
        } catch let error as SendRecipientNameError {
            throw error
        } catch {
            throw SendRecipientNameError.invalidName
        }
    }

    static func namehash(_ normalizedName: String) -> Data {
        normalizedName.split(separator: ".").reversed().reduce(
            Data(repeating: 0, count: 32)
        ) { node, label in
            let labelHash = Hash.keccak256(
                data: Data(label.utf8)
            )
            return Hash.keccak256(data: node + labelHash)
        }
    }

    static func dnsEncodedName(
        _ normalizedName: String
    ) throws -> Data {
        var result = Data()
        for label in normalizedName.split(separator: ".") {
            let bytes = Data(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 255 else {
                throw SendRecipientNameError.invalidName
            }
            result.append(UInt8(bytes.count))
            result.append(bytes)
        }
        result.append(0)
        return result
    }

    static func resolveCallData(
        normalizedName: String,
        coinType: UInt64
    ) throws -> Data {
        let resolverCall = multichainAddressSelector
            + namehash(normalizedName)
            + ABI.encodeWord(coinType)
        return resolveSelector + ABI.encodeDynamicPair(
            try dnsEncodedName(normalizedName),
            resolverCall
        )
    }

    static func decodeResolvedRecord(_ result: Data) throws -> Data {
        let resolverResult = try ABI.dynamicData(
            in: result,
            offsetWordAt: 0,
            relativeTo: 0
        )
        guard !resolverResult.isEmpty else {
            throw SendRecipientNameError.noRecordForNetwork
        }
        return try ABI.dynamicData(
            in: resolverResult,
            offsetWordAt: 0,
            relativeTo: 0
        )
    }

    private func ethCall(
        to target: String,
        data: Data,
        depth: Int,
        endpoint: URL
    ) async throws -> Data {
        guard depth <= 4 else {
            throw SendRecipientNameError.invalidServiceResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "eth_call",
                "params": [
                    [
                        "to": target,
                        "data": "0x" + data.hexString
                    ],
                    "latest"
                ]
            ]
        )

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(
                for: request
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SendRecipientNameError.serviceUnavailable
        }
        guard
            let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200,
            responseData.count <= 1_048_576,
            let object = try? JSONSerialization.jsonObject(
                with: responseData
            ) as? [String: Any]
        else {
            throw SendRecipientNameError.serviceUnavailable
        }

        if let result = object["result"] as? String {
            guard let decoded = Self.hexData(result) else {
                throw SendRecipientNameError.invalidServiceResponse
            }
            return decoded
        }
        if let errorObject = object["error"] {
            if let revertData = Self.findRevertData(in: errorObject),
               revertData.starts(
                   with: Self.offchainLookupSelector
               ) {
                return try await completeOffchainLookup(
                    revertData,
                    expectedSender: target,
                    depth: depth,
                    endpoint: endpoint
                )
            }
            throw SendRecipientNameError.noRecordForNetwork
        }
        throw SendRecipientNameError.invalidServiceResponse
    }

    private func completeOffchainLookup(
        _ revertData: Data,
        expectedSender: String,
        depth: Int,
        endpoint: URL
    ) async throws -> Data {
        let lookup = try OffchainLookup.decode(revertData)
        guard Self.sameAddress(
            lookup.sender,
            expectedSender
        ) else {
            throw SendRecipientNameError.invalidServiceResponse
        }

        var lastError: SendRecipientNameError = .serviceUnavailable
        for template in lookup.urls {
            do {
                let response = try await fetchOffchainResponse(
                    template: template,
                    sender: lookup.sender,
                    callData: lookup.callData
                )
                let callbackData = lookup.callbackFunction
                    + ABI.encodeDynamicPair(
                        response,
                        lookup.extraData
                    )
                return try await ethCall(
                    to: lookup.sender,
                    data: callbackData,
                    depth: depth + 1,
                    endpoint: endpoint
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SendRecipientNameError {
                lastError = error
            } catch {
                lastError = .serviceUnavailable
            }
        }
        throw lastError
    }

    private func fetchOffchainResponse(
        template: String,
        sender: String,
        callData: Data
    ) async throws -> Data {
        let dataHex = "0x" + callData.hexString
        let usesTemplate = template.contains("{sender}")
            || template.contains("{data}")
        let resolved = template
            .replacingOccurrences(
                of: "{sender}",
                with: sender.lowercased()
            )
            .replacingOccurrences(of: "{data}", with: dataHex)
        guard
            let url = URL(string: resolved),
            url.scheme?.lowercased() == "https"
        else {
            throw SendRecipientNameError.invalidServiceResponse
        }

        var request = URLRequest(url: url)
        if usesTemplate {
            request.httpMethod = "GET"
        } else {
            request.httpMethod = "POST"
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = try JSONSerialization.data(
                withJSONObject: [
                    "sender": sender.lowercased(),
                    "data": dataHex
                ]
            )
        }

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(
                for: request
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SendRecipientNameError.serviceUnavailable
        }
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode),
            responseData.count <= 1_048_576,
            let object = try? JSONSerialization.jsonObject(
                with: responseData
            ) as? [String: Any],
            let value = object["data"] as? String,
            let decoded = Self.hexData(value)
        else {
            throw SendRecipientNameError.invalidServiceResponse
        }
        return decoded
    }

    private static func hexData(_ value: String) -> Data? {
        let normalized = value.hasPrefix("0x")
            ? String(value.dropFirst(2))
            : value
        guard
            normalized.count.isMultiple(of: 2),
            normalized.allSatisfy(\.isHexDigit)
        else {
            return nil
        }
        return Data(hexString: normalized)
    }

    private static func findRevertData(in value: Any) -> Data? {
        if let string = value as? String,
           let data = hexData(string),
           data.starts(with: offchainLookupSelector) {
            return data
        }
        if let dictionary = value as? [String: Any] {
            for nested in dictionary.values {
                if let data = findRevertData(in: nested) {
                    return data
                }
            }
        }
        if let array = value as? [Any] {
            for nested in array {
                if let data = findRevertData(in: nested) {
                    return data
                }
            }
        }
        return nil
    }

    private static func sameAddress(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        lhs.lowercased() == rhs.lowercased()
    }

    private static func shouldFallback(_ error: Error) -> Bool {
        if ProviderReliabilityClassification.isRetryableTransport(error) {
            return true
        }
        guard let nameError = error as? SendRecipientNameError else {
            return false
        }
        return nameError == .serviceUnavailable
            || nameError == .invalidServiceResponse
    }

    private static func uniqueEndpoints(_ endpoints: [URL]) -> [URL] {
        var seen = Set<String>()
        return endpoints.filter { endpoint in
            seen.insert(endpoint.absoluteString).inserted
        }
    }
}

private enum ABI {
    static func encodeWord(_ value: UInt64) -> Data {
        var result = Data(repeating: 0, count: 32)
        for offset in 0..<8 {
            result[31 - offset] = UInt8(
                (value >> UInt64(offset * 8)) & 0xff
            )
        }
        return result
    }

    static func encodeDynamicPair(
        _ first: Data,
        _ second: Data
    ) -> Data {
        let firstTail = dynamicTail(first)
        return encodeWord(64)
            + encodeWord(UInt64(64 + firstTail.count))
            + firstTail
            + dynamicTail(second)
    }

    static func dynamicData(
        in data: Data,
        offsetWordAt wordOffset: Int,
        relativeTo base: Int
    ) throws -> Data {
        let offset = try unsignedWord(
            in: data,
            at: wordOffset
        )
        let start = try checkedAdd(base, offset)
        let length = try unsignedWord(in: data, at: start)
        let bytesStart = try checkedAdd(start, 32)
        let bytesEnd = try checkedAdd(bytesStart, length)
        guard bytesEnd <= data.count else {
            throw SendRecipientNameError.invalidServiceResponse
        }
        return data.subdata(in: bytesStart..<bytesEnd)
    }

    static func unsignedWord(
        in data: Data,
        at offset: Int
    ) throws -> Int {
        guard
            offset >= 0,
            offset <= data.count - 32,
            data[offset..<(offset + 24)].allSatisfy({ $0 == 0 })
        else {
            throw SendRecipientNameError.invalidServiceResponse
        }
        var value: UInt64 = 0
        for byte in data[(offset + 24)..<(offset + 32)] {
            value = (value << 8) | UInt64(byte)
        }
        guard value <= UInt64(Int.max) else {
            throw SendRecipientNameError.invalidServiceResponse
        }
        return Int(value)
    }

    private static func dynamicTail(_ data: Data) -> Data {
        let padding = (32 - data.count % 32) % 32
        return encodeWord(UInt64(data.count))
            + data
            + Data(repeating: 0, count: padding)
    }

    private static func checkedAdd(
        _ lhs: Int,
        _ rhs: Int
    ) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, value >= 0 else {
            throw SendRecipientNameError.invalidServiceResponse
        }
        return value
    }
}

private struct OffchainLookup {
    let sender: String
    let urls: [String]
    let callData: Data
    let callbackFunction: Data
    let extraData: Data

    static func decode(_ revertData: Data) throws -> OffchainLookup {
        guard
            revertData.count >= 4 + 160,
            revertData.starts(with: Data([0x55, 0x6f, 0x18, 0x30]))
        else {
            throw SendRecipientNameError.invalidServiceResponse
        }
        let arguments = revertData.subdata(
            in: 4..<revertData.count
        )
        let senderWord = arguments.subdata(in: 0..<32)
        guard senderWord.prefix(12).allSatisfy({ $0 == 0 }) else {
            throw SendRecipientNameError.invalidServiceResponse
        }
        let sender = "0x" + senderWord.suffix(20).hexString
        let urlsOffset = try ABI.unsignedWord(
            in: arguments,
            at: 32
        )
        let urls = try decodeStrings(
            in: arguments,
            at: urlsOffset
        )
        let callData = try ABI.dynamicData(
            in: arguments,
            offsetWordAt: 64,
            relativeTo: 0
        )
        let callbackFunction = arguments.subdata(in: 96..<100)
        let extraData = try ABI.dynamicData(
            in: arguments,
            offsetWordAt: 128,
            relativeTo: 0
        )
        guard !urls.isEmpty else {
            throw SendRecipientNameError.invalidServiceResponse
        }
        return OffchainLookup(
            sender: sender,
            urls: urls,
            callData: callData,
            callbackFunction: callbackFunction,
            extraData: extraData
        )
    }

    private static func decodeStrings(
        in data: Data,
        at arrayStart: Int
    ) throws -> [String] {
        let count = try ABI.unsignedWord(
            in: data,
            at: arrayStart
        )
        guard count <= 16 else {
            throw SendRecipientNameError.invalidServiceResponse
        }
        let offsetsStart = arrayStart + 32
        return try (0..<count).map { index in
            let relativeOffset = try ABI.unsignedWord(
                in: data,
                at: offsetsStart + index * 32
            )
            let elementStart = offsetsStart + relativeOffset
            let length = try ABI.unsignedWord(
                in: data,
                at: elementStart
            )
            let stringStart = elementStart + 32
            let stringEnd = stringStart + length
            guard
                length <= 2_048,
                stringEnd <= data.count,
                let value = String(
                    data: data.subdata(
                        in: stringStart..<stringEnd
                    ),
                    encoding: .utf8
                )
            else {
                throw SendRecipientNameError.invalidServiceResponse
            }
            return value
        }
    }
}
