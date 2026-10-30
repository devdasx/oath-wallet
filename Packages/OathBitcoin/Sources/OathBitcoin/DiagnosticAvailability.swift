import OathDiagnostics

extension BitcoinError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .timeout, .disconnected, .tls, .unavailable: true
        default: false
        }
    }
}
