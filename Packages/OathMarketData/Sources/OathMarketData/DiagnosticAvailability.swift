import OathDiagnostics

extension MarketDataError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .rateLimited, .unavailable: true
        default: false
        }
    }
}
