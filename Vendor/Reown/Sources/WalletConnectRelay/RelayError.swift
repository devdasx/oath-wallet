import Foundation
import OathDiagnostics

enum RelayError: Error, LocalizedError {
    case requestTimeout

    var errorDescription: String? {
        return localizedDescription
    }

    var localizedDescription: String {
        switch self {
        case .requestTimeout:
            return "Relay request timeout"
        }
    }
}

extension RelayError: DiagnosticAvailabilityError {
    var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .requestTimeout: return true
        }
    }
}
