import OathDiagnostics

extension ArtworkError: DiagnosticAvailabilityError {
    public var isDiagnosticAvailabilityFailure: Bool {
        switch self {
        case .http(let status): status == 408 || status == 429 || (500...599).contains(status)
        default: false
        }
    }
}
