import Foundation

/// Notification history stores TonAPI event/transaction identities, whereas
/// Send's receipt monitors a submitted external-message hash.
struct NotificationTONStatusProvider: Sendable {
    typealias Executor = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let executor: Executor

    init(executor: Executor? = nil) {
        if let executor { self.executor = executor }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 10
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration)
            self.executor = { try await session.data(for: $0) }
        }
    }

    func status(hash: String, accountAddress: String, contractAddress: String?, sender: String? = nil, recipient: String? = nil) async throws -> SendTransactionNetworkStatus {
        guard SendTransactionStatusValidation.isHexHash(hash, byteCount: 32, allowsPrefix: false),
              let account = TONAddress.rawAddress(from: accountAddress) else {
            throw SendTransactionStatusProviderError.invalidTransactionHash(networkID: TONConstants.networkID)
        }
        let url = URL(string: "https://tonapi.io/v2/events")!.appendingPathComponent(hash)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await executor(request)
        guard let http = response as? HTTPURLResponse else { throw TONProviderError.invalidResponse("status_not_http") }
        if http.statusCode == 404 { return .notFound }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = body?["error"] as? String ?? body?["message"] as? String ?? "event_status"
            throw TONProviderError.server(status: http.statusCode,
                code: SendTransactionSubmissionError.sanitizedMessage(String(message.prefix(300))))
        }
        let event: TONAPIEvents.Event
        do { event = try JSONDecoder().decode(TONAPIEvents.Event.self, from: data) }
        catch { throw TONProviderError.invalidResponse("event_status_decoding") }
        return try Self.status(event: event, account: account, contractAddress: contractAddress, sender: sender, recipient: recipient)
    }

    static func status(event: TONAPIEvents.Event, account: String, contractAddress: String?, sender: String? = nil, recipient: String? = nil) throws -> SendTransactionNetworkStatus {
        guard let inProgress = event.inProgress else { throw TONProviderError.invalidResponse("event_progress_missing") }
        if inProgress { return .pending }
        if let contractAddress, TONAddress.rawAddress(from: contractAddress) == nil {
            throw TONProviderError.invalidResponse("event_contract_invalid")
        }
        func matches(_ actualSender: String?, _ actualRecipient: String?) -> Bool {
            if let sender, TONAddress.rawAddress(from: sender) != actualSender.flatMap(TONAddress.rawAddress) { return false }
            if let recipient, TONAddress.rawAddress(from: recipient) != actualRecipient.flatMap(TONAddress.rawAddress) { return false }
            return [actualSender, actualRecipient].compactMap { $0 }.contains { TONAddress.rawAddress(from: $0) == account }
        }
        let actions = event.actions.filter { action in
            if let contractAddress {
                guard let transfer = action.jettonTransfer,
                      TONAddress.rawAddress(from: transfer.jetton.address) == TONAddress.rawAddress(from: contractAddress) else { return false }
                return matches(transfer.sender?.address, transfer.recipient?.address)
            }
            guard let transfer = action.tonTransfer else { return false }
            return matches(transfer.sender.address, transfer.recipient.address)
        }
        guard !actions.isEmpty else { throw TONProviderError.invalidResponse("event_transfer_missing") }
        if actions.allSatisfy({ $0.status == "failed" }) { return .failed }
        guard actions.allSatisfy({ $0.status == "ok" }) else { throw TONProviderError.invalidResponse("event_action_status") }
        return .confirmed
    }
}
