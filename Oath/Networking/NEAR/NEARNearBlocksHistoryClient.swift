import Foundation

struct NEARNearBlocksHistoryClient: Sendable {
    typealias Executor = @Sendable (URLRequest) async throws
        -> (Data, URLResponse)

    private enum Category: String, Sendable {
        case transactions = "txns"
        case receipts
        case tokenTransfers = "ft-txns"
    }

    private let executor: Executor

    init(session: URLSession? = nil) {
        let resolvedSession: URLSession
        if let session {
            resolvedSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 10
            resolvedSession = URLSession(configuration: configuration)
        }
        executor = { try await resolvedSession.data(for: $0) }
    }

    init(executor: @escaping Executor) {
        self.executor = executor
    }

    func history(address: String) async throws -> [NEARHistoryItem] {
        guard NEARAddress.isValid(address) else {
            throw NEARProviderError.invalidAddress
        }
        async let transactions = pages(
            category: .transactions,
            address: address,
            type: NEARNearBlocksTransaction.self
        )
        async let receipts = pages(
            category: .receipts,
            address: address,
            type: NEARNearBlocksReceipt.self
        )
        async let tokenTransfers = pages(
            category: .tokenTransfers,
            address: address,
            type: NEARNearBlocksTokenTransfer.self
        )
        let (transactionRows, receiptRows, tokenRows) = try await (
            transactions,
            receipts,
            tokenTransfers
        )
        return Self.merge(
            transactions: transactionRows,
            receipts: receiptRows,
            tokenTransfers: tokenRows,
            address: address
        )
    }

    private func pages<Item: Decodable & Sendable>(
        category: Category,
        address: String,
        type: Item.Type
    ) async throws -> [Item] {
        var output: [Item] = []
        var nextPage: String?
        for _ in 0..<NEARConstants.maximumHistoryPages {
            try Task.checkCancellation()
            let page: NEARNearBlocksPage<Item> = try await page(
                category: category,
                address: address,
                nextPage: nextPage,
                type: type
            )
            output.append(contentsOf: page.data)
            guard !page.data.isEmpty,
                  let next = page.meta?.nextPage,
                  !next.isEmpty,
                  next != nextPage
            else { break }
            nextPage = next
        }
        return output
    }

    private func page<Item: Decodable & Sendable>(
        category: Category,
        address: String,
        nextPage: String?,
        type: Item.Type
    ) async throws -> NEARNearBlocksPage<Item> {
        let path = NEARConstants.nearBlocksAPIBase
            .appending(path: "v3/accounts")
            .appending(path: address)
            .appending(path: category.rawValue)
        guard var components = URLComponents(
            url: path,
            resolvingAgainstBaseURL: false
        ) else { throw NEARProviderError.invalidConfiguration }
        components.queryItems = [
            URLQueryItem(
                name: "limit",
                value: String(NEARConstants.historyPageSize)
            )
        ]
        if let nextPage {
            components.queryItems?.append(
                URLQueryItem(name: "next", value: nextPage)
            )
        }
        guard let url = components.url else {
            throw NEARProviderError.invalidConfiguration
        }
        let (data, response) = try await executor(URLRequest(url: url))
        guard let http = response as? HTTPURLResponse else {
            throw NEARProviderError.invalidResponse("nearblocks_not_http")
        }
        if http.statusCode == 404 {
            return NEARNearBlocksPage(data: [], meta: nil)
        }
        guard 200..<300 ~= http.statusCode else {
            throw NEARProviderError.http(
                status: http.statusCode,
                code: "nearblocks_\(category.rawValue)"
            )
        }
        do {
            return try JSONDecoder().decode(
                NEARNearBlocksPage<Item>.self,
                from: data
            )
        } catch {
            throw NEARProviderError.invalidResponse(
                "nearblocks_\(category.rawValue)_decoding"
            )
        }
    }

    private static func merge(
        transactions: [NEARNearBlocksTransaction],
        receipts: [NEARNearBlocksReceipt],
        tokenTransfers: [NEARNearBlocksTokenTransfer],
        address: String
    ) -> [NEARHistoryItem] {
        var items = transactions.compactMap {
            nativeItem(transaction: $0, address: address)
        }
        var signatures = Set(items.map(nativeSignature))
        for receipt in receipts {
            guard let item = nativeItem(receipt: receipt, address: address),
                  signatures.insert(nativeSignature(item)).inserted
            else { continue }
            items.append(item)
        }
        items.append(
            contentsOf: tokenTransfers.compactMap {
                tokenItem(transfer: $0, address: address)
            }
        )
        return Dictionary(
            items.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp > $1.timestamp
            }
            return $0.id < $1.id
        }
    }

    private static func nativeItem(
        transaction: NEARNearBlocksTransaction,
        address: String
    ) -> NEARHistoryItem? {
        guard transaction.actions.contains(where: { $0.action == "TRANSFER" }),
              let atomic = canonicalUnsigned(
                transaction.actionsAggregate.deposit
              ),
              transaction.signerAccountID == address
                || transaction.receiverAccountID == address,
              let timestamp = timestamp(transaction.block.blockTimestamp),
              let height = Int64(transaction.block.blockHeight),
              let amount = try? NEARAPIClient.userUnits(
                atomic: atomic,
                decimals: NEARConstants.decimals
              )
        else { return nil }
        let outgoing = transaction.signerAccountID == address
        return NEARHistoryItem(
            id: "\(transaction.transactionHash):nearblocks:native",
            transactionHash: transaction.transactionHash,
            timestamp: timestamp,
            failed: !transaction.outcome.status,
            sender: transaction.signerAccountID,
            recipient: transaction.receiverAccountID,
            metadata: nil,
            signedAmountText: outgoing ? "-\(amount)" : amount,
            networkFeeAtomic: outgoing
                ? canonicalUnsigned(
                    transaction.outcomesAggregate.transactionFee
                ) : nil,
            blockHeight: height,
            nonce: nil
        )
    }

    private static func nativeItem(
        receipt: NEARNearBlocksReceipt,
        address: String
    ) -> NEARHistoryItem? {
        guard receipt.predecessorAccountID != "system",
              receipt.actions.contains(where: { $0.action == "TRANSFER" }),
              let atomic = canonicalUnsigned(receipt.actionsAggregate.deposit),
              receipt.predecessorAccountID == address
                || receipt.receiverAccountID == address,
              let timestamp = timestamp(receipt.includedInBlockTimestamp),
              let height = Int64(receipt.block.blockHeight),
              let amount = try? NEARAPIClient.userUnits(
                atomic: atomic,
                decimals: NEARConstants.decimals
              )
        else { return nil }
        let outgoing = receipt.predecessorAccountID == address
        return NEARHistoryItem(
            id: "\(receipt.transactionHash):nearblocks:receipt:\(receipt.receiptID)",
            transactionHash: receipt.transactionHash,
            timestamp: timestamp,
            failed: !receipt.outcome.status,
            sender: receipt.predecessorAccountID,
            recipient: receipt.receiverAccountID,
            metadata: nil,
            signedAmountText: outgoing ? "-\(amount)" : amount,
            networkFeeAtomic: nil,
            blockHeight: height,
            nonce: nil
        )
    }

    private static func tokenItem(
        transfer: NEARNearBlocksTokenTransfer,
        address: String
    ) -> NEARHistoryItem? {
        guard transfer.affectedAccountID == address,
              let signedAtomic = canonicalSignedInteger(transfer.deltaAmount),
              let timestamp = timestamp(transfer.blockTimestamp),
              let height = Int64(transfer.block.blockHeight)
        else { return nil }
        let catalog = NEARTokenCatalog.byContract[transfer.contractAccountID]
        guard let decimals = catalog?.decimals ?? transfer.metadata?.decimals,
              let name = catalog?.name ?? transfer.metadata?.name,
              let symbol = catalog?.symbol ?? transfer.metadata?.symbol,
              (0...38).contains(decimals)
        else { return nil }
        let outgoing = signedAtomic.hasPrefix("-")
        let magnitude = outgoing
            ? String(signedAtomic.dropFirst()) : signedAtomic
        guard let amount = try? NEARAPIClient.userUnits(
            atomic: magnitude,
            decimals: decimals
        ) else { return nil }
        let metadata = NEARTokenMetadata(
            contractID: transfer.contractAccountID,
            name: name,
            symbol: symbol,
            decimals: decimals,
            iconURL: catalog == nil
                ? safeIconURL(transfer.metadata?.icon) : nil,
            isVerified: catalog != nil,
            rank: catalog?.rank ?? 10_000
        )
        let counterparty = transfer.involvedAccountID ?? ""
        return NEARHistoryItem(
            id: "\(transfer.transactionHash):nearblocks:ft:\(transfer.contractAccountID):\(transfer.eventIndex ?? 0)",
            transactionHash: transfer.transactionHash,
            timestamp: timestamp,
            failed: false,
            sender: outgoing ? address : counterparty,
            recipient: outgoing ? counterparty : address,
            metadata: metadata,
            signedAmountText: outgoing ? "-\(amount)" : amount,
            networkFeeAtomic: nil,
            blockHeight: height,
            nonce: nil
        )
    }

    private static func canonicalUnsigned(_ value: String?) -> String? {
        value.flatMap(ExactDecimalText.canonicalUnsignedInteger)
    }

    private static func canonicalSignedInteger(_ value: String) -> String? {
        if value.hasPrefix("-") {
            guard let magnitude = ExactDecimalText.canonicalUnsignedInteger(
                String(value.dropFirst())
            ), magnitude != "0" else { return nil }
            return "-\(magnitude)"
        }
        return ExactDecimalText.canonicalUnsignedInteger(value)
    }

    private static func timestamp(_ nanoseconds: String) -> Double? {
        guard let value = UInt64(nanoseconds) else { return nil }
        return Double(value) / 1_000_000_000
    }

    private static func nativeSignature(_ item: NEARHistoryItem) -> String {
        "\(item.transactionHash)|\(item.sender)|\(item.recipient)|\(item.signedAmountText)"
    }

    private static func safeIconURL(_ value: String?) -> URL? {
        guard let value,
              value.utf8.count <= 2_048,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil
        else { return nil }
        return url
    }
}
