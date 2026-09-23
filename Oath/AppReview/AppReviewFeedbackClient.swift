import Foundation
import UIKit

enum AppReviewFeedbackReason: String, CaseIterable, Identifiable,
    Codable, Sendable {
    case difficultToUse = "difficult_to_use"
    case missingFeature = "missing_feature"
    case performanceOrReliability = "performance_or_reliability"
    case transactionOrNetwork = "transaction_or_network"
    case designOrAccessibility = "design_or_accessibility"
    case other

    var id: String { rawValue }

    var localizationKey: String {
        "app.review.feedback.reason.\(rawValue)"
    }
}

enum AppReviewFeedbackSubmissionError: Error, Equatable, Sendable {
    case invalidFeedback
    case configurationUnavailable
    case connection
    case server
    case invalidResponse

    var localizationKey: String {
        switch self {
        case .invalidFeedback:
            "app.review.feedback.error.invalid"
        case .configurationUnavailable:
            "app.review.feedback.error.configuration"
        case .connection, .server:
            "app.review.feedback.error.send"
        case .invalidResponse:
            "app.review.feedback.error.invalid"
        }
    }
}

protocol AppReviewFunctionInvoking: Sendable {
    func invoke(functionPath: String, payload: Data) async throws
}

/// Opens a user-controlled email draft. No feedback is uploaded in the background.
struct AppReviewEmailInvoker: AppReviewFunctionInvoking {
    func invoke(functionPath: String, payload: Data) async throws {
        guard functionPath == "feedback-email",
              let values = try JSONSerialization.jsonObject(with: payload) as? [String: String] else {
            throw AppReviewFeedbackSubmissionError.invalidFeedback
        }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = WalletSupport.emailAddress
        let reason = values["reason"] ?? "other"
        let feedback = values["feedback"] ?? ""
        let version = values["app_version"] ?? "unknown"
        let build = values["app_build"] ?? "unknown"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Oath Wallet feedback: \(reason)"),
            URLQueryItem(name: "body", value: "\(feedback)\n\nOath Wallet \(version) (\(build))")
        ]
        guard let url = components.url, await openEmailDraft(url) else {
            throw AppReviewFeedbackSubmissionError.configurationUnavailable
        }
    }

    @MainActor
    private func openEmailDraft(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { opened in
                continuation.resume(returning: opened)
            }
        }
    }
}

private struct AppReviewFeedbackPayload: Encodable, Sendable {
    let reason: String
    let feedback: String?
    let appVersion: String
    let appBuild: String
    let languageIdentifier: String

    enum CodingKeys: String, CodingKey {
        case reason
        case feedback
        case appVersion = "app_version"
        case appBuild = "app_build"
        case languageIdentifier = "language_identifier"
    }
}

struct AppReviewFeedbackClient: Sendable {
    static let maximumFeedbackLength = 2_000
    static let live = AppReviewFeedbackClient(
        invoker: AppReviewEmailInvoker()
    )

    private let invoker: any AppReviewFunctionInvoking
    private let appVersion: @Sendable () -> String
    private let appBuild: @Sendable () -> String

    init(
        invoker: any AppReviewFunctionInvoking,
        appVersion: @escaping @Sendable () -> String = {
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown"
        },
        appBuild: @escaping @Sendable () -> String = {
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown"
        }
    ) {
        self.invoker = invoker
        self.appVersion = appVersion
        self.appBuild = appBuild
    }

    func submit(
        reason: AppReviewFeedbackReason,
        feedback: String,
        languageIdentifier: String
    ) async throws {
        let normalizedFeedback = feedback.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let normalizedLanguageIdentifier =
            Self.normalizedLanguageIdentifier(languageIdentifier)
        else {
            throw AppReviewFeedbackSubmissionError.invalidFeedback
        }
        guard normalizedFeedback.count
                <= Self.maximumFeedbackLength
        else {
            throw AppReviewFeedbackSubmissionError.invalidFeedback
        }

        let payload = AppReviewFeedbackPayload(
            reason: reason.rawValue,
            feedback: normalizedFeedback.isEmpty
                ? nil
                : normalizedFeedback,
            appVersion: Self.normalizedBuildValue(appVersion()),
            appBuild: Self.normalizedBuildValue(appBuild()),
            languageIdentifier: normalizedLanguageIdentifier
        )

        let data: Data
        do {
            data = try JSONEncoder().encode(payload)
        } catch {
            throw AppReviewFeedbackSubmissionError.invalidFeedback
        }

        do {
            try await invoker.invoke(
                functionPath: "feedback-email",
                payload: data
            )
        } catch let error as AppReviewFeedbackSubmissionError {
            throw error
        } catch is URLError {
            throw AppReviewFeedbackSubmissionError.connection
        } catch {
            throw AppReviewFeedbackSubmissionError.invalidResponse
        }
    }

    private static func isValidLanguageIdentifier(_ value: String) -> Bool {
        guard (2...20).contains(value.count) else { return false }
        return value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
        }
    }

    private static func normalizedLanguageIdentifier(
        _ value: String
    ) -> String? {
        var baseIdentifier = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if let keywordSeparator = baseIdentifier.firstIndex(of: "@") {
            baseIdentifier = String(
                baseIdentifier[..<keywordSeparator]
            )
        }

        var normalized = baseIdentifier
            .replacingOccurrences(of: "_", with: "-")
        if let unicodeExtension = normalized.range(
            of: "-u-",
            options: .caseInsensitive
        ) {
            normalized = String(
                normalized[..<unicodeExtension.lowerBound]
            )
        }
        return isValidLanguageIdentifier(normalized)
            ? normalized
            : nil
    }

    private static func normalizedBuildValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 32 else {
            return "unknown"
        }
        return trimmed
    }
}
