import Foundation
import GRDB
import Testing
import UIKit
@testable import Aperture

actor TONBalanceSnapshotProbe {
    private(set) var recordCount = 0
    private(set) var nativeAtomicAmount: String?
    private(set) var historyCount = -1
    private var waiters: [UUID: (target: Int, continuation: CheckedContinuation<Void, Error>)] = [:]

    func record(_ snapshot: TONWalletSnapshot) {
        recordCount += 1
        nativeAtomicAmount = snapshot.nativeAtomicAmount
        historyCount = snapshot.history.count
        for (id, waiter) in waiters where waiter.target <= recordCount {
            waiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    func wait(until target: Int) async throws {
        try Task.checkCancellation()
        guard recordCount < target else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = (target, continuation)
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

actor TONHistoryGate {
    private var isBlocked = false
    private var isReleased = false
    private var blockedWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var releaseWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func block() async throws {
        try Task.checkCancellation()
        isBlocked = true
        blockedWaiters.values.forEach { $0.resume() }
        blockedWaiters.removeAll()
        guard !isReleased else { return }
        try await wait(forRelease: true)
    }

    func waitUntilBlocked() async throws {
        try Task.checkCancellation()
        guard !isBlocked else { return }
        try await wait(forRelease: false)
    }

    func release() {
        isReleased = true
        releaseWaiters.values.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    private func wait(forRelease: Bool) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if forRelease { releaseWaiters[id] = continuation }
                else { blockedWaiters[id] = continuation }
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        blockedWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        releaseWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

actor TONBroadcastRequestRecorder {
    struct Captured: Sendable {
        let url: URL
        let body: String
    }

    private(set) var requests: [Captured] = []
    private let emulationStatus: Int
    private let emulationActionResultCode: Int
    private let broadcastHash: String

    init(
        emulationStatus: Int = 200,
        emulationActionResultCode: Int = 0,
        broadcastHash: String = Data(repeating: 0, count: 32)
            .base64EncodedString()
    ) {
        self.emulationStatus = emulationStatus
        self.emulationActionResultCode = emulationActionResultCode
        self.broadcastHash = broadcastHash
    }

    func response(
        for request: URLRequest
    ) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        requests.append(
            Captured(
                url: url,
                body: String(
                    data: request.httpBody ?? Data(),
                    encoding: .utf8
                ) ?? ""
            )
        )
        let isEmulation = url.host == "tonapi.io"
        let status = isEmulation ? emulationStatus : 200
        let payload: String
        if isEmulation && status == 429 {
            payload = #"{"error":"rate limit exceeded"}"#
        } else if isEmulation {
            let success = emulationActionResultCode == 0
            payload = """
                {"trace":{"transaction":{"success":true,"aborted":false,\
                "action_phase":{"success":\(success),\
                "result_code":\(emulationActionResultCode)},\
                "compute_phase":{"skipped":false,"success":true,\
                "exit_code":0}},"children":[]},"risk":{},\
                "event":{"actions":[{"status":"\(success ? "ok" : "failed")"}]}}
                """
        } else {
            payload = """
                {"ok":true,"result":{"@type":"raw.extMessageInfo",\
                "hash":"\(broadcastHash)","hash_norm":"\(broadcastHash)"}}
                """
        }
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json"
                ]
            )
        )
        return (Data(payload.utf8), response)
    }
}

actor TONPaginationStub {
    private let ownerFriendlyAddress: String
    private let ownerRawAddress: String
    private let historyGate: TONHistoryGate?
    private(set) var eventCursors: [String?] = []

    init(
        ownerFriendlyAddress: String,
        ownerRawAddress: String,
        historyGate: TONHistoryGate? = nil
    ) {
        self.ownerFriendlyAddress = ownerFriendlyAddress
        self.ownerRawAddress = ownerRawAddress
        self.historyGate = historyGate
    }

    func response(for request: URLRequest) async throws -> Data {
        let path = request.url?.lastPathComponent
        switch path {
        case "account":
            return try encoded([
                "address": ownerFriendlyAddress,
                "balance": "25094973665",
                "status": "active",
                "is_scam": false
            ])
        case "jettons":
            return try encoded(["balances": []])
        case "rates":
            return try encoded([
                "rates": [
                    "TON": [
                        "prices": ["USD": 1]
                    ]
                ]
            ])
        case "events":
            if let historyGate {
                try await historyGate.block()
            }
            let cursor = try eventCursor(request)
            eventCursors.append(cursor)
            if cursor == nil {
                return try encoded([
                    "events": (0..<100).map { index in
                        [
                            "event_id": "page-one-\(index)",
                            "timestamp": 1_700_000_000,
                            "actions": [],
                            "is_scam": false,
                            "in_progress": false
                        ]
                    },
                    "next_from": 900
                ])
            }
            let recipientAddress =
                "0:" + String(repeating: "0", count: 64)
            return try encoded([
                "events": [
                    [
                        "event_id": String(repeating: "a", count: 64),
                        "timestamp": 1_699_999_999,
                        "actions": [
                            [
                                "type": "TonTransfer",
                                "status": "ok",
                                "TonTransfer": [
                                    "sender": [
                                        "address": ownerFriendlyAddress
                                    ],
                                    "recipient": [
                                        "address": recipientAddress
                                    ],
                                    "amount": 1_000_000_000
                                ]
                            ]
                        ],
                        "is_scam": false,
                        "in_progress": false
                    ]
                ]
            ])
        default:
            throw URLError(.unsupportedURL)
        }
    }

    private func requestBody(
        _ request: URLRequest
    ) throws -> [String: Any] {
        guard let data = request.httpBody,
              let body = try JSONSerialization.jsonObject(
                with: data
              ) as? [String: Any]
        else {
            throw URLError(.cannotParseResponse)
        }
        return body
    }

    private func eventCursor(_ request: URLRequest) throws -> String? {
        if request.httpBody != nil {
            return try requestBody(request)["beforeLt"] as? String
        }
        return URLComponents(
            url: try #require(request.url),
            resolvingAgainstBaseURL: false
        )?.queryItems?.first { $0.name == "before_lt" }?.value
    }

    private func encoded(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }
}
