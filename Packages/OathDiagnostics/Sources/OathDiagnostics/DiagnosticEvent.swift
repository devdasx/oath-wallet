import Foundation
import CryptoKit

/// A provider cannot supply this optional value now, or a shared scheduler is
/// respecting an already-observed cooldown or bounded queue. Keep this distinct
/// from cancellation so other providers can recover. Never use for invalid data.
public enum DiagnosticDeferral: Error, Sendable, Equatable {
    case publicMarketCooldown
    case publicMarketCapacity
    case publicMarketQuoteUnavailable
    case tokenMetadataCooldown
    case tokenMetadataCapacity
}

public protocol DiagnosticErrorProviding: Error {
    var diagnosticMessage: String { get }
    var diagnosticCode: Int { get }
}

/// Modules can identify typed cancellation/deferral without diagnostics depending
/// on those modules or suppressing unrelated errors with the same numeric code.
public protocol DiagnosticControlFlowError: Error {
    var isExpectedDiagnosticControlFlow: Bool { get }
}

/// Typed domain wrappers can retain their original cause without exposing userInfo.
public protocol DiagnosticCausalError: Error {
    var diagnosticCause: (any Error)? { get }
}

public struct DiagnosticError: Codable, Sendable, Equatable {
    public let type: String
    public let domain: String
    public let code: Int
    public let message: String
    public let reason: String?
    public let underlying: [DiagnosticError]
    public init(_ error: any Error, depth: Int = 0) {
        let ns = error as NSError
        let messageLimit = depth == 0 ? 4_096 : 1_024
        let reasonLimit = depth == 0 ? 2_048 : 512
        type = DiagnosticPrivacy.identifier(String(reflecting: Swift.type(of: error)))
        domain = DiagnosticPrivacy.identifier(ns.domain)
        code = (error as? any DiagnosticErrorProviding)?.diagnosticCode ?? ns.code
        // Preserve enum case / numeric associated codes as well as NSError text.
        // Database errors can echo SQL bind arguments: do NOT serialize them.
        if let safe = error as? any DiagnosticErrorProviding {
            message = DiagnosticPrivacy.text(safe.diagnosticMessage, limit: messageLimit)
        } else if ns.domain.contains("GRDB") || type.contains("DatabaseError") {
            message = "Database operation failed (SQL and bindings withheld)"
        } else if let decoding = error as? DecodingError {
            switch decoding {
            case .keyNotFound(let key, _): message = "Missing response field: " + DiagnosticPrivacy.text(key.stringValue, limit: messageLimit)
            case .typeMismatch(let type, _): message = "Response type mismatch: " + DiagnosticPrivacy.text(String(describing: type), limit: messageLimit)
            case .valueNotFound(let type, _): message = "Response value missing: " + DiagnosticPrivacy.text(String(describing: type), limit: messageLimit)
            case .dataCorrupted: message = "Corrupt response data"
            @unknown default: message = "Response decoding failed"
            }
        } else {
            // NSError.description dumps arbitrary userInfo when no localized
            // description exists. Only Swift domain errors use enum descriptions.
            let fallback = Swift.type(of: error) is NSError.Type ? ns.localizedDescription : String(describing: error)
            let rawMessage = ns.userInfo[NSLocalizedDescriptionKey] as? String ?? fallback
            let publicCode = DiagnosticAvailabilityPolicy.normalizedPublicCode(domain: ns.domain, message: rawMessage)
            message = DiagnosticPrivacy.text(publicCode ?? rawMessage, limit: messageLimit)
        }
        let decodingContext: DecodingError.Context?
        switch error {
        case DecodingError.keyNotFound(_, let context), DecodingError.typeMismatch(_, let context),
             DecodingError.valueNotFound(_, let context), DecodingError.dataCorrupted(let context): decodingContext = context
        default: decodingContext = nil
        }
        if let context = decodingContext {
            let path = context.codingPath.map { $0.intValue.map(String.init) ?? DiagnosticPrivacy.text($0.stringValue, limit: 80) }.joined(separator: ".")
            reason = DiagnosticPrivacy.text("Field path: " + path + "; " + context.debugDescription, limit: reasonLimit)
        } else {
            reason = (ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String).map { DiagnosticPrivacy.text($0, limit: reasonLimit) }
        }
        if depth < 3, let cause = (error as? any DiagnosticCausalError)?.diagnosticCause ?? decodingContext?.underlyingError ?? ns.userInfo[NSUnderlyingErrorKey] as? any Error {
            underlying = [DiagnosticError(cause, depth: depth + 1)]
        } else { underlying = [] }
    }
}

public struct DiagnosticEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let occurredAt: Date
    public let sessionID: UUID
    public let operationID: UUID?
    public let component: String
    public let operation: String
    public let severity: String
    public let error: DiagnosticError
    public let context: [String: String]
    public let sourceFile: String
    public let sourceFunction: String
    public let sourceLine: UInt
    public let appVersion: String
    public let appBuild: String
    public let osVersion: String
    public let fingerprint: String
    public let schemaVersion: Int
    public let privacyFiltered: Bool
    public let runtimeReport: String?

    public init(error: any Error, component: String, operation: String, severity: String = "error",
                context: [String: String] = [:], runtimeReport: String? = nil, sessionID: UUID, operationID: UUID? = nil,
                id: UUID = UUID(), occurredAt: Date = Date(), file: String = #fileID,
                function: String = #function, line: UInt = #line) {
        self.id = id; self.occurredAt = occurredAt; self.sessionID = sessionID; self.operationID = operationID
        self.component = DiagnosticPrivacy.identifier(component); self.operation = DiagnosticPrivacy.identifier(operation)
        self.severity = ["warning", "error", "fatal"].contains(severity) ? severity : "error"
        self.error = DiagnosticError(error)
        var serviceContext = DiagnosticPrivacy.context(context)
        // Unknown is explicit: never infer a cause or an origin from timing alone.
        serviceContext["cause_status"] = self.error.underlying.isEmpty ? "original_error_only" : "underlying_preserved"
        for (key, value) in ["screen": "unknown", "origin_screen": "unknown", "screen_source": "unknown",
                             "app_state": "unknown", "action": self.operation,
                             "step": DiagnosticPrivacy.identifier(function), "step_source": "source_function", "time_source": "capture_time"] where serviceContext[key] == nil {
            serviceContext[key] = value
        }
        self.context = serviceContext
        sourceFile = DiagnosticPrivacy.identifier(file); sourceFunction = DiagnosticPrivacy.identifier(function); sourceLine = line
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        schemaVersion = 1; privacyFiltered = true
        self.runtimeReport = runtimeReport.map { DiagnosticPrivacy.runtime($0) }
        let grouping = "\(self.component)|\(self.operation)|\(self.error.type)|\(self.error.code)|\(sourceFile)|\(function)|\(self.context["chain"] ?? "")"
        fingerprint = SHA256.hash(data: Data(grouping.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        // Explicit acronym mappings in CodingKeys avoid convertFromSnakeCase's ID ambiguity.
        decoder.keyDecodingStrategy = .convertFromSnakeCase; return decoder
    }
    enum CodingKeys: String, CodingKey {
        case id, occurredAt, sessionID = "sessionId", operationID = "operationId", component, operation, severity, error, context
        case sourceFile, sourceFunction, sourceLine, appVersion, appBuild, osVersion, fingerprint, schemaVersion, privacyFiltered, runtimeReport
    }
}
